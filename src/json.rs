#[derive(Debug, Clone, PartialEq)]
pub enum JsonValue {
    Object(Vec<(String, JsonValue)>),
    Array(Vec<JsonValue>),
    String(String),
    Bool(bool),
    Number(String),
    Null,
}

impl JsonValue {
    /// Returns the single property value matching `key` (exact case-sensitive),
    /// or `Err(())` if duplicate keys exist. Returns `Ok(None)` if absent.
    pub fn get_exact_unique(&self, key: &str) -> Result<Option<&JsonValue>, &'static str> {
        let JsonValue::Object(entries) = self else {
            return Err("not an object");
        };
        let mut found: Option<&JsonValue> = None;
        for (k, v) in entries {
            if k == key {
                if found.is_some() {
                    return Err("duplicate key");
                }
                found = Some(v);
            }
        }
        Ok(found)
    }

    pub fn is_object(&self) -> bool {
        matches!(self, JsonValue::Object(_))
    }

    pub fn get(&self, key: &str) -> Option<&JsonValue> {
        let JsonValue::Object(entries) = self else {
            return None;
        };
        entries.iter().rev().find(|(k, _)| k == key).map(|(_, v)| v)
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            JsonValue::String(s) => Some(s.as_str()),
            _ => None,
        }
    }

    pub fn as_bool(&self) -> Option<bool> {
        match self {
            JsonValue::Bool(b) => Some(*b),
            _ => None,
        }
    }

    pub fn as_i64(&self) -> Option<i64> {
        match self {
            JsonValue::Number(s) => s.parse::<i64>().ok(),
            _ => None,
        }
    }

    pub fn as_array(&self) -> Option<&[JsonValue]> {
        match self {
            JsonValue::Array(arr) => Some(arr.as_slice()),
            _ => None,
        }
    }

    /// Converts JSON string/number/bool scalars to string (`None` for Null/Object/Array).
    pub fn to_text_string(&self) -> Option<String> {
        match self {
            JsonValue::String(s) => Some(s.clone()),
            JsonValue::Number(n) => Some(n.clone()),
            JsonValue::Bool(b) => Some(if *b { "true" } else { "false" }.to_string()),
            JsonValue::Null | JsonValue::Object(_) | JsonValue::Array(_) => None,
        }
    }

    pub fn str(s: impl Into<String>) -> Self {
        JsonValue::String(s.into())
    }

    pub fn num_u64(n: u64) -> Self {
        JsonValue::Number(n.to_string())
    }

    pub fn num_i64(n: i64) -> Self {
        JsonValue::Number(n.to_string())
    }

    pub fn obj(entries: Vec<(String, JsonValue)>) -> Self {
        JsonValue::Object(entries)
    }

    /// Serializes as compact RFC 8259 JSON matching `JSON.stringify`.
    pub fn to_json_string(&self) -> String {
        let mut out = String::new();
        self.write_compact(&mut out);
        out
    }

    /// Serializes as 2-space indented RFC 8259 JSON matching `JSON.stringify(v, null, 2)`.
    pub fn to_json_pretty(&self) -> String {
        let mut out = String::new();
        self.write_pretty(&mut out, 0);
        out
    }

    fn write_compact(&self, out: &mut String) {
        match self {
            JsonValue::Null => out.push_str("null"),
            JsonValue::Bool(true) => out.push_str("true"),
            JsonValue::Bool(false) => out.push_str("false"),
            JsonValue::Number(n) => out.push_str(n),
            JsonValue::String(s) => escape_json_str(s, out),
            JsonValue::Array(items) => {
                out.push('[');
                for (i, item) in items.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    item.write_compact(out);
                }
                out.push(']');
            }
            JsonValue::Object(entries) => {
                out.push('{');
                for (i, (k, v)) in entries.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    escape_json_str(k, out);
                    out.push(':');
                    v.write_compact(out);
                }
                out.push('}');
            }
        }
    }

    fn write_pretty(&self, out: &mut String, indent: usize) {
        match self {
            JsonValue::Null | JsonValue::Bool(_) | JsonValue::Number(_) | JsonValue::String(_) => {
                self.write_compact(out)
            }
            JsonValue::Array(items) => {
                if items.is_empty() {
                    out.push_str("[]");
                    return;
                }
                out.push_str("[\n");
                for (i, item) in items.iter().enumerate() {
                    push_indent(out, indent + 2);
                    item.write_pretty(out, indent + 2);
                    if i + 1 < items.len() {
                        out.push(',');
                    }
                    out.push('\n');
                }
                push_indent(out, indent);
                out.push(']');
            }
            JsonValue::Object(entries) => {
                if entries.is_empty() {
                    out.push_str("{}");
                    return;
                }
                out.push_str("{\n");
                for (i, (k, v)) in entries.iter().enumerate() {
                    push_indent(out, indent + 2);
                    escape_json_str(k, out);
                    out.push_str(": ");
                    v.write_pretty(out, indent + 2);
                    if i + 1 < entries.len() {
                        out.push(',');
                    }
                    out.push('\n');
                }
                push_indent(out, indent);
                out.push('}');
            }
        }
    }
}

fn push_indent(out: &mut String, count: usize) {
    for _ in 0..count {
        out.push(' ');
    }
}

/// Appends `s` as a quoted RFC 8259 JSON string to `out`.
pub fn escape_json_str(s: &str, out: &mut String) {
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
            c if (c as u32) < 0x20 => {
                use std::fmt::Write;
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

struct Parser<'a> {
    src: &'a [u8],
    pos: usize,
}

impl<'a> Parser<'a> {
    fn skip_ws(&mut self) {
        while self.pos < self.src.len() {
            match self.src[self.pos] {
                b' ' | b'\t' | b'\r' | b'\n' => self.pos += 1,
                _ => break,
            }
        }
    }

    fn peek(&self) -> Option<u8> {
        self.src.get(self.pos).copied()
    }

    fn next(&mut self) -> Option<u8> {
        let b = self.peek()?;
        self.pos += 1;
        Some(b)
    }

    fn parse_value(&mut self) -> Result<JsonValue, String> {
        self.skip_ws();
        let b = self
            .peek()
            .ok_or_else(|| "unexpected end of JSON".to_string())?;
        match b {
            b'{' => self.parse_object(),
            b'[' => self.parse_array(),
            b'"' => self.parse_string().map(JsonValue::String),
            b't' => self.parse_literal(b"true", JsonValue::Bool(true)),
            b'f' => self.parse_literal(b"false", JsonValue::Bool(false)),
            b'n' => self.parse_literal(b"null", JsonValue::Null),
            b'-' | b'0'..=b'9' => self.parse_number(),
            _ => Err(format!("unexpected byte 0x{b:02x}")),
        }
    }

    fn parse_literal(&mut self, lit: &[u8], val: JsonValue) -> Result<JsonValue, String> {
        if self.src[self.pos..].starts_with(lit) {
            self.pos += lit.len();
            Ok(val)
        } else {
            Err("invalid JSON literal".to_string())
        }
    }

    fn parse_number(&mut self) -> Result<JsonValue, String> {
        let start = self.pos;
        if self.peek() == Some(b'-') {
            self.pos += 1;
        }
        match self.peek() {
            Some(b'0') => self.pos += 1,
            Some(b'1'..=b'9') => {
                self.pos += 1;
                while matches!(self.peek(), Some(b'0'..=b'9')) {
                    self.pos += 1;
                }
            }
            _ => return Err("invalid JSON number".to_string()),
        }
        if self.peek() == Some(b'.') {
            self.pos += 1;
            if !matches!(self.peek(), Some(b'0'..=b'9')) {
                return Err("invalid JSON fraction".to_string());
            }
            while matches!(self.peek(), Some(b'0'..=b'9')) {
                self.pos += 1;
            }
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            self.pos += 1;
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.pos += 1;
            }
            if !matches!(self.peek(), Some(b'0'..=b'9')) {
                return Err("invalid JSON exponent".to_string());
            }
            while matches!(self.peek(), Some(b'0'..=b'9')) {
                self.pos += 1;
            }
        }
        let s = std::str::from_utf8(&self.src[start..self.pos])
            .map_err(|_| "invalid utf8 in number".to_string())?;
        Ok(JsonValue::Number(s.to_string()))
    }

    fn parse_hex4(&mut self) -> Result<u16, String> {
        if self.pos + 4 > self.src.len() {
            return Err("truncated \\u escape".to_string());
        }
        let hex_str = std::str::from_utf8(&self.src[self.pos..self.pos + 4])
            .map_err(|_| "invalid \\u escape".to_string())?;
        self.pos += 4;
        u16::from_str_radix(hex_str, 16).map_err(|_| "invalid hex in \\u escape".to_string())
    }

    fn parse_string(&mut self) -> Result<String, String> {
        if self.next() != Some(b'"') {
            return Err("expected '\"'".to_string());
        }
        let mut out = String::new();
        loop {
            let b = self
                .next()
                .ok_or_else(|| "unterminated string".to_string())?;
            if b == b'"' {
                return Ok(out);
            }
            if b < 0x20 {
                return Err("unescaped control character in JSON string".to_string());
            }
            if b == b'\\' {
                let esc = self
                    .next()
                    .ok_or_else(|| "unterminated escape".to_string())?;
                match esc {
                    b'"' => out.push('"'),
                    b'\\' => out.push('\\'),
                    b'/' => out.push('/'),
                    b'b' => out.push('\u{0008}'),
                    b'f' => out.push('\u{000C}'),
                    b'n' => out.push('\n'),
                    b'r' => out.push('\r'),
                    b't' => out.push('\t'),
                    b'u' => {
                        let code = self.parse_hex4()?;
                        if (0xD800..=0xDBFF).contains(&code) {
                            if !self.src[self.pos..].starts_with(b"\\u") {
                                return Err("unpaired high surrogate in JSON string".to_string());
                            }
                            self.pos += 2;
                            let low = self.parse_hex4()?;
                            if !(0xDC00..=0xDFFF).contains(&low) {
                                return Err("invalid low surrogate in JSON string".to_string());
                            }
                            let cp =
                                0x10000 + (((code as u32 - 0xD800) << 10) | (low as u32 - 0xDC00));
                            let ch = char::from_u32(cp)
                                .ok_or_else(|| "invalid unicode scalar".to_string())?;
                            out.push(ch);
                        } else if (0xDC00..=0xDFFF).contains(&code) {
                            return Err("unpaired low surrogate in JSON string".to_string());
                        } else {
                            let ch = char::from_u32(code as u32)
                                .ok_or_else(|| "invalid unicode scalar".to_string())?;
                            out.push(ch);
                        }
                    }
                    _ => return Err("invalid escape sequence in JSON string".to_string()),
                }
            } else if b < 0x80 {
                out.push(b as char);
            } else {
                // Multi-byte UTF-8 sequence starting at self.pos - 1
                let start = self.pos - 1;
                let width = if (b & 0xE0) == 0xC0 {
                    2
                } else if (b & 0xF0) == 0xE0 {
                    3
                } else if (b & 0xF8) == 0xF0 {
                    4
                } else {
                    return Err("invalid UTF-8 byte in JSON string".to_string());
                };
                if start + width > self.src.len() {
                    return Err("truncated UTF-8 sequence in JSON string".to_string());
                }
                let s = std::str::from_utf8(&self.src[start..start + width])
                    .map_err(|_| "invalid UTF-8 sequence in JSON string".to_string())?;
                out.push_str(s);
                self.pos = start + width;
            }
        }
    }

    fn parse_array(&mut self) -> Result<JsonValue, String> {
        self.pos += 1; // '['
        self.skip_ws();
        let mut items = Vec::new();
        if self.peek() == Some(b']') {
            self.pos += 1;
            return Ok(JsonValue::Array(items));
        }
        loop {
            items.push(self.parse_value()?);
            self.skip_ws();
            match self.next() {
                Some(b',') => continue,
                Some(b']') => return Ok(JsonValue::Array(items)),
                _ => return Err("expected ',' or ']' in array".to_string()),
            }
        }
    }

    fn parse_object(&mut self) -> Result<JsonValue, String> {
        self.pos += 1; // '{'
        self.skip_ws();
        let mut entries = Vec::new();
        if self.peek() == Some(b'}') {
            self.pos += 1;
            return Ok(JsonValue::Object(entries));
        }
        loop {
            self.skip_ws();
            let key = self.parse_string()?;
            self.skip_ws();
            if self.next() != Some(b':') {
                return Err("expected ':' after object key".to_string());
            }
            let val = self.parse_value()?;
            entries.push((key, val));
            self.skip_ws();
            match self.next() {
                Some(b',') => continue,
                Some(b'}') => return Ok(JsonValue::Object(entries)),
                _ => return Err("expected ',' or '}' in object".to_string()),
            }
        }
    }
}

/// Strictly parses an RFC 8259 JSON text (stripping optional leading UTF-8 BOM).
pub fn parse_json(raw: &str) -> Result<JsonValue, String> {
    let trimmed = raw.trim_start_matches('\u{FEFF}').trim();
    if trimmed.is_empty() {
        return Err("empty JSON".to_string());
    }
    let mut p = Parser {
        src: trimmed.as_bytes(),
        pos: 0,
    };
    let val = p.parse_value()?;
    p.skip_ws();
    if p.pos != p.src.len() {
        return Err("trailing characters after JSON value".to_string());
    }
    Ok(val)
}
