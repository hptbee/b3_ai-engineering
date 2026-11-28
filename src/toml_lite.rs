//! Zero-dependency strict TOML subset parser and comment-preserving key updater.

use std::collections::{BTreeMap, BTreeSet};

/// Hard resource bounds for zero-dependency strict TOML parsing.
pub const MAX_TOML_BYTES: usize = 256 * 1024;
pub const MAX_TABLE_SEGMENTS: usize = 6;
pub const MAX_ARRAY_ITEMS: usize = 256;
pub const MAX_TABLES: usize = 128;
pub const MAX_KEYS_TOTAL: usize = 512;
pub const MAX_STRING_BYTES: usize = 4096;

/// Parsed TOML value for B3 configuration and governance policy files.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TomlValue {
    Str(String),
    Bool(bool),
    Int(i64),
    Array(Vec<TomlValue>),
}

impl TomlValue {
    pub fn as_str(&self) -> Option<&str> {
        match self {
            TomlValue::Str(s) => Some(s.as_str()),
            _ => None,
        }
    }

    pub fn as_bool(&self) -> Option<bool> {
        match self {
            TomlValue::Bool(b) => Some(*b),
            _ => None,
        }
    }

    pub fn as_i64(&self) -> Option<i64> {
        match self {
            TomlValue::Int(n) => Some(*n),
            _ => None,
        }
    }

    pub fn as_array(&self) -> Option<&[TomlValue]> {
        match self {
            TomlValue::Array(arr) => Some(arr.as_slice()),
            _ => None,
        }
    }
}

/// Parsed TOML document mapping table names (`""` for root) to key-value maps.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TomlDocument {
    pub tables: BTreeMap<String, BTreeMap<String, TomlValue>>,
}

impl TomlDocument {
    pub fn table(&self, name: &str) -> Option<&BTreeMap<String, TomlValue>> {
        self.tables.get(name)
    }

    pub fn get(&self, table: &str, key: &str) -> Option<&TomlValue> {
        self.tables.get(table).and_then(|t| t.get(key))
    }
}

fn is_bare_key_byte(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_' || b == b'-'
}

fn strip_bom_slice(raw: &str) -> (&str, usize) {
    if let Some(rest) = raw.strip_prefix('\u{FEFF}') {
        (rest, '\u{FEFF}'.len_utf8())
    } else {
        (raw, 0)
    }
}

#[derive(Debug, Clone)]
struct ParsedAssignment {
    table: String,
    key: String,
    val_start: usize,
    val_end: usize,
    line_end: usize,
}

#[derive(Debug, Clone)]
struct ParsedTableSpan {
    name: String,
    start: usize,
    end: usize,
}

struct Parser<'a> {
    src: &'a str,
    bytes: &'a [u8],
    pos: usize,
    line: usize,
}

impl<'a> Parser<'a> {
    fn new(src: &'a str) -> Self {
        Self {
            src,
            bytes: src.as_bytes(),
            pos: 0,
            line: 1,
        }
    }

    fn err(&self, msg: impl Into<String>) -> String {
        format!("line {}: {}", self.line, msg.into())
    }

    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.pos).copied()
    }

    fn advance_char(&mut self) -> Option<char> {
        let ch = self.src[self.pos..].chars().next()?;
        self.pos += ch.len_utf8();
        if ch == '\n' {
            self.line += 1;
        }
        Some(ch)
    }

    fn skip_hspace(&mut self) {
        while let Some(b) = self.peek() {
            if b == b' ' || b == b'\t' {
                self.pos += 1;
            } else {
                break;
            }
        }
    }

    fn skip_comment(&mut self) {
        if self.peek() == Some(b'#') {
            while let Some(ch) = self.advance_char() {
                if ch == '\n' {
                    break;
                }
            }
        }
    }

    fn skip_ws_and_comments(&mut self) {
        loop {
            while let Some(b) = self.peek() {
                match b {
                    b' ' | b'\t' | b'\r' => self.pos += 1,
                    b'\n' => {
                        self.pos += 1;
                        self.line += 1;
                    }
                    _ => break,
                }
            }
            if self.peek() == Some(b'#') {
                self.skip_comment();
                continue;
            }
            break;
        }
    }

    fn skip_eol_and_comment(&mut self) -> Result<usize, String> {
        self.skip_hspace();
        match self.peek() {
            None => Ok(self.pos),
            Some(b'#') => {
                while let Some(b) = self.peek() {
                    if b == b'\n' || b == b'\r' {
                        break;
                    }
                    self.advance_char();
                }
                let end = self.pos;
                self.consume_newline();
                Ok(end)
            }
            Some(b'\r') | Some(b'\n') => {
                let end = self.pos;
                self.consume_newline();
                Ok(end)
            }
            Some(_) => Err(self.err("unexpected trailing tokens after value")),
        }
    }

    fn consume_newline(&mut self) {
        if self.peek() == Some(b'\r') {
            self.pos += 1;
        }
        if self.peek() == Some(b'\n') {
            self.pos += 1;
            self.line += 1;
        }
    }

    fn parse_bare_key(&mut self) -> Result<String, String> {
        let start = self.pos;
        while let Some(b) = self.peek() {
            if is_bare_key_byte(b) {
                self.pos += 1;
            } else {
                break;
            }
        }
        if self.pos == start {
            return Err(self.err("expected key name"));
        }
        Ok(self.src[start..self.pos].to_string())
    }

    fn parse_table_header(&mut self) -> Result<String, String> {
        self.pos += 1; // consume '['
        if self.peek() == Some(b'[') {
            return Err(self.err("array-of-tables syntax '[[' is not supported"));
        }
        let mut parts = Vec::new();
        loop {
            self.skip_hspace();
            let part = self.parse_bare_key()?;
            parts.push(part);
            if parts.len() > MAX_TABLE_SEGMENTS {
                return Err(self.err(format!(
                    "table header exceeds maximum depth of {MAX_TABLE_SEGMENTS} segments"
                )));
            }
            self.skip_hspace();
            match self.peek() {
                Some(b'.') => {
                    self.pos += 1;
                }
                Some(b']') => {
                    self.pos += 1;
                    break;
                }
                _ => return Err(self.err("malformed table header; expected '.' or ']'")),
            }
        }
        self.skip_eol_and_comment()?;
        Ok(parts.join("."))
    }

    fn parse_basic_string(&mut self) -> Result<String, String> {
        self.pos += 1; // opening '"'
        if self.src[self.pos..].starts_with("\"\"") {
            return Err(self.err("multi-line basic strings '\"\"\"' are not supported"));
        }
        let mut out = String::new();
        loop {
            let Some(ch) = self.advance_char() else {
                return Err(self.err("unterminated string literal"));
            };
            match ch {
                '"' => return Ok(out),
                '\n' | '\r' => return Err(self.err("newline inside basic string literal")),
                c if c.is_control() && c != '\t' => {
                    return Err(self.err("unescaped control character in string literal"))
                }
                '\\' => {
                    let Some(esc) = self.advance_char() else {
                        return Err(self.err("unterminated escape sequence"));
                    };
                    match esc {
                        '"' => out.push('"'),
                        '\\' => out.push('\\'),
                        'b' => out.push('\u{0008}'),
                        'f' => out.push('\u{000C}'),
                        'n' => out.push('\n'),
                        'r' => out.push('\r'),
                        't' => out.push('\t'),
                        'u' => out.push(self.parse_unicode_escape(4)?),
                        'U' => out.push(self.parse_unicode_escape(8)?),
                        other => {
                            return Err(self.err(format!("invalid escape sequence '\\{other}'")))
                        }
                    }
                }
                c => out.push(c),
            }
            if out.len() > MAX_STRING_BYTES {
                return Err(self.err(format!(
                    "string literal exceeds maximum length of {MAX_STRING_BYTES} bytes"
                )));
            }
        }
    }

    fn parse_unicode_escape(&mut self, digits: usize) -> Result<char, String> {
        let mut hex = String::with_capacity(digits);
        for _ in 0..digits {
            let Some(c) = self.advance_char() else {
                return Err(self.err("truncated unicode escape"));
            };
            if !c.is_ascii_hexdigit() {
                return Err(self.err("non-hex digit in unicode escape"));
            }
            hex.push(c);
        }
        let code =
            u32::from_str_radix(&hex, 16).map_err(|_| self.err("invalid unicode scalar escape"))?;
        char::from_u32(code).ok_or_else(|| self.err("invalid unicode scalar codepoint"))
    }

    fn parse_literal_string(&mut self) -> Result<String, String> {
        self.pos += 1; // opening '\''
        if self.src[self.pos..].starts_with("''") {
            return Err(self.err("multi-line literal strings \"'''\" are not supported"));
        }
        let mut out = String::new();
        loop {
            let Some(ch) = self.advance_char() else {
                return Err(self.err("unterminated literal string"));
            };
            match ch {
                '\'' => return Ok(out),
                '\n' | '\r' => return Err(self.err("newline inside literal string")),
                c if c.is_control() && c != '\t' => {
                    return Err(self.err("control character inside literal string"))
                }
                c => out.push(c),
            }
            if out.len() > MAX_STRING_BYTES {
                return Err(self.err(format!(
                    "string literal exceeds maximum length of {MAX_STRING_BYTES} bytes"
                )));
            }
        }
    }

    fn parse_scalar_value(&mut self) -> Result<TomlValue, String> {
        match self.peek() {
            Some(b'"') => self.parse_basic_string().map(TomlValue::Str),
            Some(b'\'') => self.parse_literal_string().map(TomlValue::Str),
            Some(b'[') => Err(self.err("nested arrays are not supported")),
            Some(b't') if self.src[self.pos..].starts_with("true") => {
                let after = self.bytes.get(self.pos + 4).copied();
                if is_token_delimiter(after) {
                    self.pos += 4;
                    Ok(TomlValue::Bool(true))
                } else {
                    Err(self.err("invalid bare value"))
                }
            }
            Some(b'f') if self.src[self.pos..].starts_with("false") => {
                let after = self.bytes.get(self.pos + 5).copied();
                if is_token_delimiter(after) {
                    self.pos += 5;
                    Ok(TomlValue::Bool(false))
                } else {
                    Err(self.err("invalid bare value"))
                }
            }
            Some(b'+' | b'-' | b'0'..=b'9') => self.parse_int().map(TomlValue::Int),
            _ => Err(self.err("expected TOML scalar value")),
        }
    }

    fn parse_value(&mut self) -> Result<TomlValue, String> {
        match self.peek() {
            Some(b'[') => self.parse_array(),
            _ => self.parse_scalar_value(),
        }
    }

    fn parse_int(&mut self) -> Result<i64, String> {
        let start = self.pos;
        if matches!(self.peek(), Some(b'+' | b'-')) {
            self.pos += 1;
        }
        let digits_start = self.pos;
        let mut prev_underscore = false;
        while let Some(b) = self.peek() {
            match b {
                b'0'..=b'9' => {
                    prev_underscore = false;
                    self.pos += 1;
                }
                b'_' if self.pos > digits_start && !prev_underscore => {
                    prev_underscore = true;
                    self.pos += 1;
                }
                _ => break,
            }
        }
        if self.pos == digits_start || prev_underscore {
            return Err(self.err("invalid integer literal"));
        }
        if !is_token_delimiter(self.peek()) {
            return Err(self.err("unsupported numeric/bare literal (expected integer)"));
        }
        let raw_num = &self.src[start..self.pos];
        let unsigned_part = raw_num.trim_start_matches(['+', '-']);
        if unsigned_part.len() > 1 && unsigned_part.starts_with('0') {
            return Err(self.err("leading zeros are not allowed in TOML integers"));
        }
        let clean: String = raw_num.chars().filter(|&c| c != '_').collect();
        clean
            .parse::<i64>()
            .map_err(|_| self.err("integer out of signed 64-bit range"))
    }

    fn parse_array(&mut self) -> Result<TomlValue, String> {
        self.pos += 1; // consume '['
        let mut items = Vec::new();
        loop {
            self.skip_ws_and_comments();
            if self.peek() == Some(b']') {
                self.pos += 1;
                return Ok(TomlValue::Array(items));
            }
            if items.len() >= MAX_ARRAY_ITEMS {
                return Err(self.err(format!(
                    "array exceeds maximum length of {MAX_ARRAY_ITEMS} items"
                )));
            }
            let item = self.parse_scalar_value()?;
            items.push(item);
            self.skip_ws_and_comments();
            match self.peek() {
                Some(b',') => {
                    self.pos += 1;
                }
                Some(b']') => {
                    self.pos += 1;
                    return Ok(TomlValue::Array(items));
                }
                _ => return Err(self.err("expected ',' or ']' in array")),
            }
        }
    }
}

fn is_token_delimiter(b: Option<u8>) -> bool {
    matches!(
        b,
        None | Some(b' ' | b'\t' | b'\r' | b'\n' | b'#' | b',' | b']')
    )
}

fn parse_with_spans(
    src: &str,
) -> Result<(TomlDocument, Vec<ParsedAssignment>, Vec<ParsedTableSpan>), String> {
    if src.len() > MAX_TOML_BYTES {
        return Err(format!(
            "TOML document exceeds maximum size of {MAX_TOML_BYTES} bytes"
        ));
    }
    let mut parser = Parser::new(src);
    let mut doc = TomlDocument::default();
    let mut seen_tables = BTreeSet::new();
    let mut current_table = String::new();
    let mut assignments = Vec::new();
    let mut table_spans: Vec<ParsedTableSpan> = Vec::new();

    loop {
        parser.skip_ws_and_comments();
        let Some(b) = parser.peek() else {
            break;
        };
        if b == b'[' {
            let header_start = parser.pos;
            if let Some(last) = table_spans.last_mut() {
                last.end = header_start;
            }
            let name = parser.parse_table_header()?;
            if !seen_tables.insert(name.clone()) {
                return Err(parser.err(format!("duplicate table header '[{name}]'")));
            }
            if doc.tables.len() >= MAX_TABLES {
                return Err(parser.err(format!(
                    "TOML document exceeds maximum of {MAX_TABLES} tables"
                )));
            }
            doc.tables.entry(name.clone()).or_default();
            table_spans.push(ParsedTableSpan {
                name: name.clone(),
                start: header_start,
                end: src.len(),
            });
            current_table = name;
            continue;
        }

        if assignments.len() >= MAX_KEYS_TOTAL {
            return Err(parser.err(format!(
                "TOML document exceeds maximum of {MAX_KEYS_TOTAL} keys"
            )));
        }
        let key = parser.parse_bare_key()?;
        parser.skip_hspace();
        if parser.peek() != Some(b'=') {
            return Err(parser.err(format!("expected '=' after key '{key}'")));
        }
        parser.pos += 1;
        parser.skip_hspace();
        let val_start = parser.pos;
        let val = parser.parse_value()?;
        let val_end = parser.pos;
        let line_end = parser.skip_eol_and_comment()?;

        let tbl = doc.tables.entry(current_table.clone()).or_default();
        if tbl.contains_key(&key) {
            return Err(parser.err(format!(
                "duplicate key '{key}' in table '{}'",
                if current_table.is_empty() {
                    "<root>"
                } else {
                    current_table.as_str()
                }
            )));
        }
        tbl.insert(key.clone(), val);
        assignments.push(ParsedAssignment {
            table: current_table.clone(),
            key,
            val_start,
            val_end,
            line_end,
        });
    }

    Ok((doc, assignments, table_spans))
}

/// Strictly parses a UTF-8 TOML string into a [`TomlDocument`].
pub fn parse_toml_strict(input: &str) -> Result<TomlDocument, String> {
    if input.len() > MAX_TOML_BYTES {
        return Err(format!(
            "TOML document exceeds maximum size of {MAX_TOML_BYTES} bytes"
        ));
    }
    let (body, _) = strip_bom_slice(input);
    let (doc, _, _) = parse_with_spans(body)?;
    Ok(doc)
}

/// Formats a [`TomlValue`] as canonical single-line TOML.
pub fn format_toml_value(val: &TomlValue) -> String {
    match val {
        TomlValue::Str(s) => format_toml_str(s),
        TomlValue::Bool(b) => if *b { "true" } else { "false" }.to_string(),
        TomlValue::Int(n) => n.to_string(),
        TomlValue::Array(items) => {
            let rendered: Vec<String> = items.iter().map(format_toml_value).collect();
            format!("[{}]", rendered.join(", "))
        }
    }
}

fn format_toml_str(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{0008}' => out.push_str("\\b"),
            '\u{000C}' => out.push_str("\\f"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c.is_control() => out.push_str(&format!("\\u{:04X}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn validate_write_value(val: &TomlValue) -> Result<(), String> {
    match val {
        TomlValue::Str(s) if s.len() > MAX_STRING_BYTES => Err(format!(
            "string literal exceeds maximum length of {MAX_STRING_BYTES} bytes"
        )),
        TomlValue::Array(items) => {
            if items.len() > MAX_ARRAY_ITEMS {
                return Err(format!(
                    "array exceeds maximum length of {MAX_ARRAY_ITEMS} items"
                ));
            }
            for item in items {
                match item {
                    TomlValue::Array(_) => {
                        return Err("nested arrays are not supported".to_string())
                    }
                    TomlValue::Str(s) if s.len() > MAX_STRING_BYTES => {
                        return Err(format!(
                            "string literal exceeds maximum length of {MAX_STRING_BYTES} bytes"
                        ))
                    }
                    _ => {}
                }
            }
            Ok(())
        }
        _ => Ok(()),
    }
}

/// Updates `key` inside `table` (`""` for root) while preserving existing comments,
/// blank lines, key order, and inline trailing comments.
pub fn set_toml_key_preserving_comments(
    raw: &str,
    table: &str,
    key: &str,
    val: &TomlValue,
) -> Result<String, String> {
    if raw.len() > MAX_TOML_BYTES {
        return Err(format!(
            "TOML document exceeds maximum size of {MAX_TOML_BYTES} bytes"
        ));
    }
    if !key.bytes().all(is_bare_key_byte) || key.is_empty() {
        return Err(format!("invalid TOML key '{key}'"));
    }
    if !table.is_empty() {
        let segs: Vec<&str> = table.split('.').collect();
        if segs.len() > MAX_TABLE_SEGMENTS
            || !segs
                .iter()
                .all(|seg| !seg.is_empty() && seg.bytes().all(is_bare_key_byte))
        {
            return Err(format!("invalid TOML table '{table}'"));
        }
    }
    validate_write_value(val)?;

    let (body, bom_len) = strip_bom_slice(raw);
    let (_, assignments, table_spans) = parse_with_spans(body)?;
    let formatted = format_toml_value(val);
    let mut result_body = String::with_capacity(body.len() + key.len() + formatted.len() + 24);

    if let Some(hit) = assignments
        .iter()
        .find(|a| a.table == table && a.key == key)
    {
        result_body.push_str(&body[..hit.val_start]);
        result_body.push_str(&formatted);
        result_body.push_str(&body[hit.val_end..]);
    } else if table.is_empty() {
        let insert_at = table_spans.first().map(|t| t.start).unwrap_or(body.len());
        let prefix = body[..insert_at].trim_end_matches(['\r', '\n']);
        if !prefix.is_empty() {
            result_body.push_str(prefix);
            result_body.push('\n');
        }
        result_body.push_str(&format!("{key} = {formatted}\n"));
        let suffix = &body[insert_at..];
        if !suffix.is_empty() {
            result_body.push('\n');
            result_body.push_str(suffix.trim_start_matches(['\r', '\n']));
        }
    } else if let Some(tspan) = table_spans.iter().find(|t| t.name == table) {
        let insert_after = assignments
            .iter()
            .filter(|a| a.table == table)
            .map(|a| a.line_end)
            .max()
            .unwrap_or_else(|| {
                // Directly after `[table]` header line.
                body[tspan.start..tspan.end]
                    .find('\n')
                    .map(|idx| tspan.start + idx)
                    .unwrap_or(tspan.end)
            });
        let before = &body[..insert_after];
        let after = &body[insert_after..];
        result_body.push_str(before);
        if !before.ends_with('\n') {
            result_body.push('\n');
        }
        result_body.push_str(&format!("{key} = {formatted}"));
        if !after.starts_with(['\r', '\n']) {
            result_body.push('\n');
        }
        result_body.push_str(after);
    } else {
        let trimmed = body.trim_end_matches(['\r', '\n']);
        if !trimmed.is_empty() {
            result_body.push_str(trimmed);
            result_body.push_str("\n\n");
        }
        result_body.push_str(&format!("[{table}]\n{key} = {formatted}\n"));
    }

    let final_text = if bom_len > 0 {
        // Normalize away BOM on write via LF output while confirming parse integrity.
        result_body
    } else {
        result_body
    };
    parse_toml_strict(&final_text)?;
    Ok(final_text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_valid_toml_with_comments_arrays_and_nested_tables() {
        let raw = "\u{FEFF}# Header\nflag = true\ncount = -42\n\n[models]\nrouting = \"adaptive\" # comment\nmax_escalations = 2\n\n[models.roles]\nplanning = [\n  \"economy\",\n  # balanced tier\n  'balanced',\n  \"advanced\",\n]\n";
        let doc = parse_toml_strict(raw).expect("parse valid toml");
        assert_eq!(doc.get("", "flag"), Some(&TomlValue::Bool(true)));
        assert_eq!(doc.get("", "count"), Some(&TomlValue::Int(-42)));
        assert_eq!(
            doc.get("models", "routing"),
            Some(&TomlValue::Str("adaptive".to_string()))
        );
        assert_eq!(
            doc.get("models", "max_escalations"),
            Some(&TomlValue::Int(2))
        );
        assert_eq!(
            doc.get("models.roles", "planning"),
            Some(&TomlValue::Array(vec![
                TomlValue::Str("economy".to_string()),
                TomlValue::Str("balanced".to_string()),
                TomlValue::Str("advanced".to_string()),
            ]))
        );
    }

    #[test]
    fn rejects_duplicate_keys_duplicate_tables_and_invalid_syntax() {
        assert!(parse_toml_strict("a = 1\na = 2\n").is_err());
        assert!(parse_toml_strict("[models]\nx = 1\n[models]\ny = 2\n").is_err());
        assert!(parse_toml_strict("[models]\nx = \"unterminated\n").is_err());
        assert!(parse_toml_strict("[models]\nx = [\"a\", \"b\"\n").is_err());
        assert!(parse_toml_strict("[models]\nx = 1.5\n").is_err());
        assert!(parse_toml_strict("[models]\nx = \"bad\\q\"\n").is_err());
    }

    #[test]
    fn updates_keys_while_preserving_comments_and_inline_notes() {
        let orig = "# Top comment\n[models]\n# routing strategy\nrouting = \"adaptive\" # keep inline\nmax_escalations = 2\n\n[models.roles]\nmain = [\"balanced\", \"advanced\"]\n";
        let updated1 = set_toml_key_preserving_comments(
            orig,
            "models",
            "routing",
            &TomlValue::Str("fixed".to_string()),
        )
        .expect("update routing");
        assert!(updated1.contains("# Top comment"));
        assert!(updated1.contains("# routing strategy"));
        assert!(updated1.contains("routing = \"fixed\" # keep inline"));

        let updated2 = set_toml_key_preserving_comments(
            &updated1,
            "models.hosts.cursor",
            "balanced",
            &TomlValue::Str("custom-model".to_string()),
        )
        .expect("append new host table");
        let parsed = parse_toml_strict(&updated2).expect("re-parse updated");
        assert_eq!(
            parsed.get("models", "routing"),
            Some(&TomlValue::Str("fixed".to_string()))
        );
        assert_eq!(
            parsed.get("models.hosts.cursor", "balanced"),
            Some(&TomlValue::Str("custom-model".to_string()))
        );
    }

    #[test]
    fn parses_canonical_example_templates() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
        let cfg_raw = std::fs::read_to_string(root.join("config/config.example.toml"))
            .expect("read config.example.toml");
        let cfg_doc = parse_toml_strict(&cfg_raw).expect("parse config.example.toml");
        assert_eq!(
            cfg_doc.get("models", "routing"),
            Some(&TomlValue::Str("adaptive".to_string()))
        );
        assert_eq!(
            cfg_doc.get("planning", "understanding_threshold"),
            Some(&TomlValue::Int(96))
        );

        let pol_raw = std::fs::read_to_string(root.join("config/policy.example.toml"))
            .expect("read policy.example.toml");
        let pol_doc = parse_toml_strict(&pol_raw).expect("parse policy.example.toml");
        assert_eq!(
            pol_doc.get("", "auto_merge"),
            Some(&TomlValue::Str("disabled".to_string()))
        );
        assert_eq!(
            pol_doc.get("", "auto_merge_max_risk"),
            Some(&TomlValue::Str("LOW".to_string()))
        );
    }

    #[test]
    fn enforces_parser_resource_and_type_bounds() {
        // Document size cap
        let too_big = format!("k = \"{}\"\n", "a".repeat(MAX_TOML_BYTES + 1));
        assert!(parse_toml_strict(&too_big).is_err());

        // String length cap
        let long_str = format!("k = \"{}\"\n", "a".repeat(MAX_STRING_BYTES + 1));
        assert!(parse_toml_strict(&long_str).is_err());

        // Nested arrays rejected cleanly
        assert!(parse_toml_strict("k = [[1]]\n").is_err());
        assert!(parse_toml_strict("k = [[\"a\"], [\"b\"]]\n").is_err());

        // Array item cap
        let many_items = format!(
            "k = [{}]\n",
            (0..=MAX_ARRAY_ITEMS)
                .map(|i| i.to_string())
                .collect::<Vec<_>>()
                .join(", ")
        );
        assert!(parse_toml_strict(&many_items).is_err());

        // Table segment depth cap
        assert!(parse_toml_strict("[a.b.c.d.e.f]\nx = 1\n").is_ok());
        assert!(parse_toml_strict("[a.b.c.d.e.f.g]\nx = 1\n").is_err());

        // Max keys & max tables caps
        let mut many_keys = String::new();
        for i in 0..=MAX_KEYS_TOTAL {
            many_keys.push_str(&format!("k{i} = 1\n"));
        }
        assert!(parse_toml_strict(&many_keys).is_err());

        let mut many_tables = String::new();
        for i in 0..=MAX_TABLES {
            many_tables.push_str(&format!("[t{i}]\nx = 1\n"));
        }
        assert!(parse_toml_strict(&many_tables).is_err());

        // Inline tables, multiline strings, array-of-tables rejected
        assert!(parse_toml_strict("k = { a = 1 }\n").is_err());
        assert!(parse_toml_strict("k = \"\"\"hello\"\"\"\n").is_err());
        assert!(parse_toml_strict("[[arr]]\nx = 1\n").is_err());
    }
}
