use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fs;
use std::path::{Path, PathBuf};

use crate::error::{fail, B3Error};
use crate::fs::{is_reparse_or_symlink, sha256_bytes_hex};
use crate::git::run_git;
use crate::guard::verify::verify_check;
use crate::json::{parse_json, JsonValue};
use crate::pr::gh_exec::{
    exec_gh, needs_bash_for_gh, resolve_bash_binary, resolve_gh_binary, validate_pr_number,
    validate_repo_slug,
};
use crate::pr::state::{
    append_state_record, assert_mutation_owner_allowed, canonicalize_clean,
    get_unresolved_pending_records, pr_emit, pr_fail, read_safe_input_file, read_state_records,
    resolve_canonical_state_path, resolve_git_context, validate_raw_path_syntax,
    validate_safe_path, with_state_lock, PrExit, EXIT_BLOCKED, EXIT_ERROR, EXIT_OK, MAX_FILE_BYTES,
};

const MAX_BODY_CHARS: usize = 65_536;
const DEFAULT_MAX_PAGES: u64 = 20;
const MAX_ALLOWED_PAGES: u64 = 100;

const UNTRUSTED_START: &str = "BEGIN_UNTRUSTED_PR_DATA";
const UNTRUSTED_END: &str = "END_UNTRUSTED_PR_DATA";

const BOOLEAN_FLAGS: &[&str] = &[
    "include-resolved",
    "include-bodies",
    "authorize-write",
    "authorize-resolve",
    "draft",
];

fn allowed_flags_for(cmd: &str) -> Option<&'static [&'static str]> {
    match cmd {
        "fetch" => Some(&[
            "repo",
            "pr",
            "include-resolved",
            "include-bodies",
            "thread-id",
            "max-pages",
        ]),
        "reconcile" => Some(&["repo", "pr", "repo-root", "max-pages"]),
        "reply" => Some(&[
            "repo",
            "pr",
            "repo-root",
            "expected-head",
            "target-kind",
            "target-id",
            "body-file",
            "idempotency-key",
            "authorize-write",
            "draft",
            "max-pages",
        ]),
        "resolve" => Some(&[
            "repo",
            "pr",
            "repo-root",
            "expected-head",
            "thread-id",
            "fix-commit",
            "evidence-file",
            "authorize-resolve",
            "draft",
            "max-pages",
        ]),
        "comment" => Some(&[
            "repo",
            "pr",
            "repo-root",
            "expected-head",
            "mode",
            "event",
            "summary-file",
            "inline-json",
            "idempotency-key",
            "authorize-write",
            "authorize-review-event",
            "draft",
            "max-pages",
        ]),
        _ => None,
    }
}

fn truncate_chars(s: &str, max_chars: usize) -> String {
    s.chars().take(max_chars).collect()
}

fn replace_ascii_case_insensitive(input: &str, needle: &str, replacement: &str) -> String {
    if needle.is_empty() || input.len() < needle.len() {
        return input.to_string();
    }
    let in_bytes = input.as_bytes();
    let n_bytes = needle.as_bytes();
    let mut out = String::with_capacity(input.len());
    let mut i = 0usize;
    while i < in_bytes.len() {
        if i + n_bytes.len() <= in_bytes.len()
            && in_bytes[i..i + n_bytes.len()].eq_ignore_ascii_case(n_bytes)
        {
            out.push_str(replacement);
            i += n_bytes.len();
        } else {
            let ch = input[i..].chars().next().unwrap_or('\0');
            out.push(ch);
            i += ch.len_utf8();
        }
    }
    out
}

pub fn sanitize_untrusted_text(val: &str) -> String {
    let mut cleaned = String::with_capacity(val.len());
    for ch in val.chars() {
        let cp = ch as u32;
        if matches!(cp, 0x00..=0x08 | 0x0B | 0x0C | 0x0E..=0x1F | 0x7F)
            || matches!(
                cp,
                0x061C | 0x200E | 0x200F | 0x202A..=0x202E | 0x2066..=0x2069
            )
            || matches!(cp, 0xE0000..=0xE007F)
        {
            continue;
        }
        cleaned.push(ch);
    }
    let step1 = replace_ascii_case_insensitive(
        &cleaned,
        "BEGIN_UNTRUSTED_PR_DATA",
        "BEGIN-UNTRUSTED-PR-DATA-ESCAPED",
    );
    replace_ascii_case_insensitive(
        &step1,
        "END_UNTRUSTED_PR_DATA",
        "END-UNTRUSTED-PR-DATA-ESCAPED",
    )
}

fn frame_untrusted_text(val: &str) -> String {
    format!(
        "{UNTRUSTED_START}\n{}\n{UNTRUSTED_END}",
        sanitize_untrusted_text(val)
    )
}

fn normalize_text(s: &str) -> String {
    s.replace("\r\n", "\n").trim().to_string()
}

fn scan_b3_markers(s: &str) -> Vec<(usize, usize, String, String)> {
    let mut hits = Vec::new();
    let bytes = s.as_bytes();
    let mut pos = 0usize;
    while let Some(rel_start) = s[pos..].find("<!--") {
        let start = pos + rel_start;
        let mut p = start + 4;
        while p < bytes.len() && bytes[p].is_ascii_whitespace() {
            p += 1;
        }
        if !bytes[p..].starts_with(b"b3-pr-key:") {
            pos = start + 4;
            continue;
        }
        p += b"b3-pr-key:".len();
        let key_start = p;
        while p < bytes.len()
            && p - key_start < 80
            && (bytes[p].is_ascii_alphanumeric() || matches!(bytes[p], b'.' | b'_' | b':' | b'-'))
        {
            p += 1;
        }
        let key_len = p - key_start;
        if key_len < 4 {
            pos = start + 4;
            continue;
        }
        let key = s[key_start..p].to_string();
        let mut op_hash = String::new();
        if bytes[p..].starts_with(b";op=") {
            let op_start = p + 4;
            if op_start + 16 > bytes.len()
                || !bytes[op_start..op_start + 16]
                    .iter()
                    .all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
            {
                pos = start + 4;
                continue;
            }
            op_hash = s[op_start..op_start + 16].to_string();
            p = op_start + 16;
        }
        while p < bytes.len() && bytes[p].is_ascii_whitespace() {
            p += 1;
        }
        if !bytes[p..].starts_with(b"-->") {
            pos = start + 4;
            continue;
        }
        let end = p + 3;
        hits.push((start, end, key, op_hash));
        pos = end;
    }
    hits
}

fn strip_markers(s: &str) -> String {
    let hits = scan_b3_markers(s);
    if hits.is_empty() {
        return normalize_text(s);
    }
    let mut stripped = String::with_capacity(s.len());
    let mut cursor = 0usize;
    for (start, end, _, _) in hits {
        if start > cursor {
            stripped.push_str(&s[cursor..start]);
        }
        cursor = end;
    }
    if cursor < s.len() {
        stripped.push_str(&s[cursor..]);
    }
    normalize_text(&stripped)
}

fn append_marker(body: &str, marker: &str) -> String {
    let cleaned = strip_markers(body);
    if cleaned.is_empty() {
        marker.to_string()
    } else {
        format!("{cleaned}\n\n{marker}")
    }
}

fn sha256_utf8_hex(s: &str) -> String {
    sha256_bytes_hex(s.as_bytes())
}

fn err_simple(status: &str, message: impl Into<String>) -> PrExit {
    pr_fail(status, message, EXIT_ERROR, Vec::new())
}

fn err_blocked_before_write(
    status: &str,
    message: impl Into<String>,
    mut extra: Vec<(String, JsonValue)>,
) -> PrExit {
    let mut base = vec![
        (
            "outcome".to_string(),
            JsonValue::str("blocked_before_write"),
        ),
        ("mutated".to_string(), JsonValue::Bool(false)),
    ];
    base.append(&mut extra);
    pr_fail(status, message, EXIT_BLOCKED, base)
}

#[derive(Debug, Default)]
struct ParsedFlags {
    values: BTreeMap<String, String>,
    bools: BTreeSet<String>,
}

impl ParsedFlags {
    fn str_opt(&self, name: &str) -> Option<&str> {
        self.values.get(name).map(String::as_str)
    }

    fn bool_flag(&self, name: &str) -> bool {
        self.bools.contains(name)
    }
}

fn parse_cli_flags(cmd: &str, args: &[String]) -> Result<ParsedFlags, PrExit> {
    let Some(allowed) = allowed_flags_for(cmd) else {
        return Err(err_simple(
            "PR_INVALID_ARGS",
            format!(
                "Unknown subcommand: {cmd} (expected: fetch, reply, resolve, comment, reconcile)"
            ),
        ));
    };
    let mut parsed = ParsedFlags::default();
    let mut i = 0usize;
    while i < args.len() {
        let arg = &args[i];
        if !arg.starts_with("--") {
            return Err(err_simple(
                "PR_INVALID_ARGS",
                format!("Unexpected positional argument: {arg}"),
            ));
        }
        let name = &arg[2..];
        if name.is_empty() || !allowed.contains(&name) {
            return Err(err_simple(
                "PR_INVALID_ARGS",
                format!("Flag --{name} is not allowed for subcommand {cmd}"),
            ));
        }
        if BOOLEAN_FLAGS.contains(&name) {
            parsed.bools.insert(name.to_string());
            i += 1;
        } else {
            if i + 1 >= args.len() || args[i + 1].starts_with("--") {
                return Err(err_simple(
                    "PR_INVALID_ARGS",
                    format!("Missing value for --{name}"),
                ));
            }
            parsed.values.insert(name.to_string(), args[i + 1].clone());
            i += 2;
        }
    }
    Ok(parsed)
}

#[derive(Debug, Clone)]
struct RepoSlug {
    owner: String,
    name: String,
    full: String,
}

fn validate_repo_flag(raw: Option<&str>) -> Result<RepoSlug, PrExit> {
    let val = raw.unwrap_or("");
    match validate_repo_slug(val) {
        Ok((owner, name, full)) => Ok(RepoSlug { owner, name, full }),
        Err("invalid_repo_segments") => {
            Err(err_simple("PR_INVALID_ARGS", "Invalid --repo segments"))
        }
        Err(_) => Err(err_simple(
            "PR_INVALID_ARGS",
            "Invalid --repo (expected owner/repo)",
        )),
    }
}

fn validate_pr_flag(raw: Option<&str>) -> Result<u64, PrExit> {
    let val = raw.unwrap_or("");
    validate_pr_number(val).map(|(n, _)| n).map_err(|_| {
        err_simple(
            "PR_INVALID_ARGS",
            "Invalid --pr (expected positive integer)",
        )
    })
}

fn validate_sha_flag(raw: Option<&str>, flag_name: &str) -> Result<String, PrExit> {
    let s = raw.unwrap_or("");
    if s.len() != 40 || crate::fs::has_control_chars(s) || !s.bytes().all(|b| b.is_ascii_hexdigit())
    {
        return Err(err_simple(
            "PR_INVALID_ARGS",
            format!("Invalid {flag_name} (expected 40-hex commit SHA)"),
        ));
    }
    Ok(s.to_ascii_lowercase())
}

fn is_valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && !crate::fs::has_control_chars(id)
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'=' | b'-'))
}

fn validate_id_flag(raw: Option<&str>, flag_name: &str) -> Result<String, PrExit> {
    let id = raw.unwrap_or("");
    if !is_valid_id(id) {
        return Err(err_simple(
            "PR_INVALID_ARGS",
            format!("Invalid {flag_name}"),
        ));
    }
    Ok(id.to_string())
}

fn validate_key_flag(raw: Option<&str>) -> Result<String, PrExit> {
    let Some(key) = raw else {
        return Ok(String::new());
    };
    if !(4..=80).contains(&key.len())
        || crate::fs::has_control_chars(key)
        || !key
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b':' | b'-'))
    {
        return Err(err_simple(
            "PR_INVALID_ARGS",
            "Invalid --idempotency-key (expected 4-80 chars of [A-Za-z0-9._:-])",
        ));
    }
    Ok(key.to_string())
}

fn validate_max_pages_flag(raw: Option<&str>) -> Result<u64, PrExit> {
    let Some(val) = raw else {
        return Ok(DEFAULT_MAX_PAGES);
    };
    let (num, _) = validate_pr_number(val)
        .map_err(|_| err_simple("PR_INVALID_ARGS", "Invalid --max-pages"))?;
    if !(1..=MAX_ALLOWED_PAGES).contains(&num) {
        return Err(err_simple(
            "PR_INVALID_ARGS",
            format!("--max-pages must be between 1 and {MAX_ALLOWED_PAGES}"),
        ));
    }
    Ok(num)
}

fn validate_rel_path(p: &str, label: &str) -> Result<String, PrExit> {
    if p.is_empty()
        || crate::fs::has_control_chars(p)
        || p.starts_with('/')
        || p.contains('\\')
        || p.split('/').any(|seg| seg == "..")
    {
        return Err(err_simple(
            "PR_INVALID_ARGS",
            format!("Invalid relative path in {label}"),
        ));
    }
    Ok(p.to_string())
}

fn is_safe_gh_arg(a: &str) -> bool {
    !a.is_empty()
        && a.bytes().all(|b| {
            b.is_ascii_alphanumeric()
                || matches!(b, b'_' | b'.' | b'/' | b':' | b'?' | b'=' | b'&' | b'-')
        })
}

enum GhResponse {
    NotFound,
    Data(Option<JsonValue>),
}

fn invoke_gh(
    args: &[String],
    stdin_str: Option<&str>,
    allow_not_found: bool,
) -> Result<GhResponse, PrExit> {
    for a in args {
        if !is_safe_gh_arg(a) {
            return Err(err_simple(
                "PR_INVALID_ARGS",
                format!("Unsafe gh argument rejected: {a}"),
            ));
        }
    }
    let env_gh = std::env::var("B3_GH_BIN").unwrap_or_default();
    if !env_gh.is_empty() && (crate::fs::has_control_chars(&env_gh) || env_gh.contains('"')) {
        return Err(err_simple(
            "PR_API_ERROR",
            "Unsafe path for gh CLI rejected",
        ));
    }
    let Some(gh_bin) = resolve_gh_binary("") else {
        return Err(err_simple("PR_API_ERROR", "gh CLI not found in PATH"));
    };
    let bash_bin = if needs_bash_for_gh(&gh_bin) {
        resolve_bash_binary("")
    } else {
        None
    };
    let res = exec_gh(
        args,
        &gh_bin,
        bash_bin.as_deref(),
        stdin_str.map(str::as_bytes),
        Some(60_000),
    );
    if !res.ok {
        let msg = match res.reason {
            "gh_not_found" => "gh CLI not found in PATH".to_string(),
            "unsafe_gh_path" => "Unsafe path for gh CLI rejected".to_string(),
            "unsafe_gh_arg" => {
                return Err(err_simple("PR_INVALID_ARGS", "Unsafe gh argument rejected"));
            }
            "timeout" => "gh CLI timed out".to_string(),
            other => format!("Failed to invoke gh: {other}"),
        };
        return Err(err_simple("PR_API_ERROR", msg));
    }
    let stdout = res.stdout.trim();
    let stderr = res.stderr.trim();
    if res.status != Some(0) {
        let combined = format!("{stderr}\n{stdout}");
        if allow_not_found
            && (combined.contains("404") || combined.to_ascii_lowercase().contains("not found"))
        {
            return Ok(GhResponse::NotFound);
        }
        let code_disp = res
            .status
            .map_or_else(|| "null".to_string(), |c| c.to_string());
        let snippet_src = if !stderr.is_empty() { stderr } else { stdout };
        let snippet = truncate_chars(&sanitize_untrusted_text(snippet_src), 300);
        return Err(err_simple(
            "PR_API_ERROR",
            format!("gh api failed (exit {code_disp}): {snippet}"),
        ));
    }
    if stdout.is_empty() {
        return Ok(GhResponse::Data(None));
    }
    let parsed = parse_json(stdout)
        .map_err(|_| err_simple("PR_API_ERROR", "gh api returned non-JSON output"))?;
    Ok(GhResponse::Data(Some(parsed)))
}

fn gh_graphql(query: &str, variables: JsonValue) -> Result<JsonValue, PrExit> {
    let payload = JsonValue::Object(vec![
        ("query".to_string(), JsonValue::str(query)),
        ("variables".to_string(), variables),
    ])
    .to_json_string();
    let args = vec![
        "api".to_string(),
        "graphql".to_string(),
        "--input".to_string(),
        "-".to_string(),
    ];
    let resp = invoke_gh(&args, Some(&payload), false)?;
    let GhResponse::Data(Some(data)) = resp else {
        return Err(err_simple("PR_API_ERROR", "Empty GraphQL response"));
    };
    if !data.is_object() {
        return Err(err_simple("PR_API_ERROR", "Empty GraphQL response"));
    }
    if let Some(errs) = data.get("errors").and_then(JsonValue::as_array) {
        if !errs.is_empty() {
            let joined: Vec<String> = errs
                .iter()
                .map(|e| {
                    e.get("message")
                        .and_then(JsonValue::as_str)
                        .unwrap_or("GraphQL error")
                        .to_string()
                })
                .collect();
            let snippet = truncate_chars(&sanitize_untrusted_text(&joined.join("; ")), 300);
            return Err(err_simple(
                "PR_API_ERROR",
                format!("GraphQL error: {snippet}"),
            ));
        }
    }
    let Some(inner) = data.get("data") else {
        return Err(err_simple(
            "PR_API_ERROR",
            "Missing data in GraphQL response",
        ));
    };
    if matches!(inner, JsonValue::Null) {
        return Err(err_simple(
            "PR_API_ERROR",
            "Missing data in GraphQL response",
        ));
    }
    Ok(inner.clone())
}

fn gh_rest_get(endpoint: &str, allow_not_found: bool) -> Result<GhResponse, PrExit> {
    let args = vec!["api".to_string(), endpoint.to_string()];
    invoke_gh(&args, None, allow_not_found)
}

fn gh_rest_post(endpoint: &str, body_obj: &JsonValue) -> Result<Option<JsonValue>, PrExit> {
    let args = vec![
        "api".to_string(),
        endpoint.to_string(),
        "--method".to_string(),
        "POST".to_string(),
        "--input".to_string(),
        "-".to_string(),
    ];
    match invoke_gh(&args, Some(&body_obj.to_json_string()), false)? {
        GhResponse::NotFound => Ok(None),
        GhResponse::Data(v) => Ok(v),
    }
}

fn fetch_rest_paginated(endpoint_base: &str, max_pages: u64) -> Result<Vec<JsonValue>, PrExit> {
    let mut items = Vec::new();
    let sep = if endpoint_base.contains('?') {
        '&'
    } else {
        '?'
    };
    for page in 1..=max_pages {
        let ep = format!("{endpoint_base}{sep}per_page=100&page={page}");
        let GhResponse::Data(Some(data)) = gh_rest_get(&ep, false)? else {
            return Err(err_simple(
                "PR_API_ERROR",
                format!("Expected array from {endpoint_base}"),
            ));
        };
        let Some(arr) = data.as_array() else {
            return Err(err_simple(
                "PR_API_ERROR",
                format!("Expected array from {endpoint_base}"),
            ));
        };
        let count = arr.len();
        items.extend(arr.iter().cloned());
        if count < 100 {
            return Ok(items);
        }
    }
    Err(err_blocked_before_write(
        "PR_PAGINATION_INCOMPLETE",
        format!("Pagination reached --max-pages ({max_pages}) on {endpoint_base}"),
        Vec::new(),
    ))
}

#[derive(Debug, Clone)]
struct PrHeader {
    viewer: String,
    state: String,
    head_sha: String,
}

fn fetch_pr_header(owner: &str, repo: &str, pr_number: u64) -> Result<PrHeader, PrExit> {
    let query = "query($owner: String!, $repo: String!, $pr: Int!) {
    viewer { login }
    repository(owner: $owner, name: $repo) { pullRequest(number: $pr) { number state headRefOid } }
  }";
    let vars = JsonValue::obj(vec![
        ("owner".to_string(), JsonValue::str(owner)),
        ("repo".to_string(), JsonValue::str(repo)),
        ("pr".to_string(), JsonValue::num_u64(pr_number)),
    ]);
    let data = gh_graphql(query, vars)?;
    let viewer = data
        .get("viewer")
        .and_then(|v| v.get("login"))
        .and_then(JsonValue::as_str)
        .unwrap_or("")
        .to_string();
    let pr = data
        .get("repository")
        .and_then(|r| r.get("pullRequest"))
        .filter(|v| !matches!(v, JsonValue::Null));
    let Some(pr_val) = pr else {
        return Err(err_simple(
            "PR_TARGET_MISMATCH",
            format!("Pull request {owner}/{repo}#{pr_number} not found"),
        ));
    };
    if viewer.is_empty() {
        return Err(err_simple(
            "PR_API_ERROR",
            "Unable to resolve authenticated viewer.login",
        ));
    }
    let state = pr_val
        .get("state")
        .and_then(JsonValue::as_str)
        .unwrap_or("")
        .to_string();
    let head_sha = pr_val
        .get("headRefOid")
        .and_then(JsonValue::as_str)
        .unwrap_or("")
        .to_ascii_lowercase();
    Ok(PrHeader {
        viewer,
        state,
        head_sha,
    })
}

fn assert_open_and_fresh_head(header: &PrHeader, expected_head: &str) -> Result<(), PrExit> {
    if header.state != "OPEN" {
        return Err(err_blocked_before_write(
            "PR_NOT_OPEN",
            format!("Pull request state is {}; expected OPEN", header.state),
            vec![("state".to_string(), JsonValue::str(&header.state))],
        ));
    }
    if header.head_sha != expected_head {
        return Err(err_blocked_before_write(
            "PR_STALE_HEAD",
            format!(
                "Remote PR HEAD ({}) does not match expected ({expected_head})",
                header.head_sha
            ),
            vec![
                ("remote_head".to_string(), JsonValue::str(&header.head_sha)),
                ("expected_head".to_string(), JsonValue::str(expected_head)),
            ],
        ));
    }
    Ok(())
}

#[derive(Debug, Clone)]
struct ThreadComment {
    id: String,
    author: String,
    body: Option<String>,
}

#[derive(Debug, Clone)]
struct ReviewThread {
    id: String,
    is_resolved: bool,
    is_outdated: bool,
    path: String,
    line: Option<i64>,
    total_count: i64,
    has_more_nested_comments: bool,
    comments: Vec<ThreadComment>,
}

fn paginate_nested_thread_comments(
    thread_id: &str,
    initial_conn: Option<&JsonValue>,
    max_pages: u64,
    include_bodies: bool,
) -> Result<Vec<JsonValue>, PrExit> {
    let fields = if include_bodies {
        "id author { login } body"
    } else {
        "id author { login }"
    };
    let query = format!(
        "query($threadId: ID!, $cursor: String) {{
    node(id: $threadId) {{ ... on PullRequestReviewThread {{ comments(first: 100, after: $cursor) {{ pageInfo {{ hasNextPage endCursor }} nodes {{ {fields} }} }} }} }}
  }}"
    );
    let mut comments: Vec<JsonValue> = initial_conn
        .and_then(|c| c.get("nodes"))
        .and_then(JsonValue::as_array)
        .map(|s| s.to_vec())
        .unwrap_or_default();
    let mut has_next = initial_conn
        .and_then(|c| c.get("pageInfo"))
        .and_then(|p| p.get("hasNextPage"))
        .and_then(JsonValue::as_bool)
        .unwrap_or(false);
    let mut end_cursor = initial_conn
        .and_then(|c| c.get("pageInfo"))
        .and_then(|p| p.get("endCursor"))
        .and_then(JsonValue::as_str)
        .map(str::to_string);

    let mut page = 1u64;
    while has_next {
        if page >= max_pages {
            return Err(err_blocked_before_write(
                "PR_PAGINATION_INCOMPLETE",
                format!(
                    "Nested comment pagination reached --max-pages ({max_pages}) on thread {thread_id}"
                ),
                Vec::new(),
            ));
        }
        let cursor_val = match &end_cursor {
            Some(c) => JsonValue::str(c),
            None => JsonValue::Null,
        };
        let vars = JsonValue::obj(vec![
            ("threadId".to_string(), JsonValue::str(thread_id)),
            ("cursor".to_string(), cursor_val),
        ]);
        let data = gh_graphql(&query, vars)?;
        let n_conn = data
            .get("node")
            .and_then(|n| n.get("comments"))
            .ok_or_else(|| {
                err_simple(
                    "PR_API_ERROR",
                    format!("Unexpected nested comment response for thread {thread_id}"),
                )
            })?;
        let Some(nodes) = n_conn.get("nodes").and_then(JsonValue::as_array) else {
            return Err(err_simple(
                "PR_API_ERROR",
                format!("Unexpected nested comment response for thread {thread_id}"),
            ));
        };
        comments.extend(nodes.iter().cloned());
        has_next = n_conn
            .get("pageInfo")
            .and_then(|p| p.get("hasNextPage"))
            .and_then(JsonValue::as_bool)
            .unwrap_or(false);
        end_cursor = n_conn
            .get("pageInfo")
            .and_then(|p| p.get("endCursor"))
            .and_then(JsonValue::as_str)
            .map(str::to_string);
        page += 1;
    }
    Ok(comments)
}

fn fetch_single_review_thread(
    repo_full: &str,
    pr_number: u64,
    thread_id: &str,
    max_pages: u64,
    include_comments: bool,
) -> Result<Option<ReviewThread>, PrExit> {
    let c_block = if include_comments {
        "comments(first: 100) { totalCount pageInfo { hasNextPage endCursor } nodes { id author { login } body } }"
    } else {
        "comments(first: 1) { totalCount }"
    };
    let query = format!(
        "query($threadId: ID!) {{
    node(id: $threadId) {{
      ... on PullRequestReviewThread {{
        id isResolved isOutdated path line originalLine
        pullRequest {{ number repository {{ nameWithOwner }} }}
        {c_block}
      }}
    }}
  }}"
    );
    let vars = JsonValue::obj(vec![("threadId".to_string(), JsonValue::str(thread_id))]);
    let data = gh_graphql(&query, vars)?;
    let Some(node) = data.get("node").filter(|v| !matches!(v, JsonValue::Null)) else {
        return Ok(None);
    };
    let Some(node_id) = node.get("id").and_then(JsonValue::to_text_string) else {
        return Ok(None);
    };
    if node_id.is_empty() {
        return Ok(None);
    }
    let owner_repo = node
        .get("pullRequest")
        .and_then(|pr| pr.get("repository"))
        .and_then(|r| r.get("nameWithOwner"))
        .and_then(JsonValue::as_str)
        .unwrap_or("")
        .to_ascii_lowercase();
    let node_pr = node
        .get("pullRequest")
        .and_then(|pr| pr.get("number"))
        .and_then(JsonValue::as_i64)
        .unwrap_or(0);
    if owner_repo.is_empty()
        || owner_repo != repo_full.to_ascii_lowercase()
        || node_pr != pr_number as i64
    {
        let repo_disp = if owner_repo.is_empty() {
            "unknown"
        } else {
            &owner_repo
        };
        return Err(err_simple(
            "PR_TARGET_MISMATCH",
            format!("Review thread {thread_id} belongs to {repo_disp}#{node_pr}, not {repo_full}#{pr_number}"),
        ));
    }
    let raw_comments = if include_comments {
        paginate_nested_thread_comments(thread_id, node.get("comments"), max_pages, true)?
    } else {
        Vec::new()
    };
    let total_count = node
        .get("comments")
        .and_then(|c| c.get("totalCount"))
        .and_then(JsonValue::as_i64)
        .unwrap_or(raw_comments.len() as i64);
    let line = node
        .get("line")
        .and_then(JsonValue::as_i64)
        .or_else(|| node.get("originalLine").and_then(JsonValue::as_i64));
    let comments = raw_comments
        .iter()
        .map(|c| ThreadComment {
            id: c
                .get("id")
                .and_then(JsonValue::to_text_string)
                .unwrap_or_default(),
            author: c
                .get("author")
                .and_then(|a| a.get("login"))
                .and_then(JsonValue::as_str)
                .filter(|s| !s.is_empty())
                .unwrap_or("unknown")
                .to_string(),
            body: Some(
                c.get("body")
                    .and_then(JsonValue::as_str)
                    .unwrap_or("")
                    .to_string(),
            ),
        })
        .collect();
    Ok(Some(ReviewThread {
        id: node_id,
        is_resolved: node
            .get("isResolved")
            .and_then(JsonValue::as_bool)
            .unwrap_or(false),
        is_outdated: node
            .get("isOutdated")
            .and_then(JsonValue::as_bool)
            .unwrap_or(false),
        path: node
            .get("path")
            .and_then(JsonValue::as_str)
            .unwrap_or("")
            .to_string(),
        line,
        total_count,
        has_more_nested_comments: false,
        comments,
    }))
}

#[derive(Debug, Clone)]
struct PrMeta {
    number: u64,
    state: String,
    head_sha: String,
    title: String,
    base_ref_name: String,
    head_ref_name: String,
    body: Option<String>,
}

fn fetch_all_review_threads(
    owner: &str,
    repo: &str,
    pr_number: u64,
    max_pages: u64,
    include_bodies: bool,
) -> Result<(String, PrMeta, Vec<ReviewThread>), PrExit> {
    let fields = if include_bodies {
        "id author { login } body"
    } else {
        "id author { login }"
    };
    let pr_body_field = if include_bodies { "body" } else { "" };
    let query = format!(
        "query($owner: String!, $repo: String!, $pr: Int!, $cursor: String) {{
    viewer {{ login }}
    repository(owner: $owner, name: $repo) {{
      pullRequest(number: $pr) {{
        number state headRefOid title baseRefName headRefName {pr_body_field}
        reviewThreads(first: 100, after: $cursor) {{
          pageInfo {{ hasNextPage endCursor }}
          nodes {{
            id isResolved isOutdated path line originalLine
            comments(first: 100) {{ totalCount pageInfo {{ hasNextPage endCursor }} nodes {{ {fields} }} }}
          }}
        }}
      }}
    }}
  }}"
    );
    let mut cursor: Option<String> = None;
    let mut viewer = String::new();
    let mut pr_meta: Option<PrMeta> = None;
    let mut threads = Vec::new();

    for _page in 1..=max_pages {
        let cursor_val = match &cursor {
            Some(c) => JsonValue::str(c),
            None => JsonValue::Null,
        };
        let vars = JsonValue::obj(vec![
            ("owner".to_string(), JsonValue::str(owner)),
            ("repo".to_string(), JsonValue::str(repo)),
            ("pr".to_string(), JsonValue::num_u64(pr_number)),
            ("cursor".to_string(), cursor_val),
        ]);
        let data = gh_graphql(&query, vars)?;
        if viewer.is_empty() {
            if let Some(v) = data
                .get("viewer")
                .and_then(|vw| vw.get("login"))
                .and_then(JsonValue::as_str)
            {
                viewer = v.to_string();
            }
        }
        let pr = data
            .get("repository")
            .and_then(|r| r.get("pullRequest"))
            .filter(|v| !matches!(v, JsonValue::Null));
        let Some(pr_val) = pr else {
            return Err(err_simple(
                "PR_TARGET_MISMATCH",
                format!("Pull request {owner}/{repo}#{pr_number} not found"),
            ));
        };
        if pr_meta.is_none() {
            pr_meta = Some(PrMeta {
                number: pr_val
                    .get("number")
                    .and_then(JsonValue::as_i64)
                    .map(|n| n.max(0) as u64)
                    .unwrap_or(pr_number),
                state: pr_val
                    .get("state")
                    .and_then(JsonValue::as_str)
                    .unwrap_or("")
                    .to_string(),
                head_sha: pr_val
                    .get("headRefOid")
                    .and_then(JsonValue::as_str)
                    .unwrap_or("")
                    .to_ascii_lowercase(),
                title: pr_val
                    .get("title")
                    .and_then(JsonValue::as_str)
                    .unwrap_or("")
                    .to_string(),
                base_ref_name: pr_val
                    .get("baseRefName")
                    .and_then(JsonValue::as_str)
                    .unwrap_or("")
                    .to_string(),
                head_ref_name: pr_val
                    .get("headRefName")
                    .and_then(JsonValue::as_str)
                    .unwrap_or("")
                    .to_string(),
                body: if include_bodies {
                    Some(
                        pr_val
                            .get("body")
                            .and_then(JsonValue::as_str)
                            .unwrap_or("")
                            .to_string(),
                    )
                } else {
                    None
                },
            });
        }
        let rt = pr_val.get("reviewThreads");
        if let Some(nodes) = rt
            .and_then(|r| r.get("nodes"))
            .and_then(JsonValue::as_array)
        {
            for t in nodes {
                let Some(tid) = t.get("id").and_then(JsonValue::to_text_string) else {
                    continue;
                };
                if tid.is_empty() {
                    continue;
                }
                let cc = t.get("comments");
                let raw_comments = if include_bodies {
                    paginate_nested_thread_comments(&tid, cc, max_pages, true)?
                } else {
                    cc.and_then(|c| c.get("nodes"))
                        .and_then(JsonValue::as_array)
                        .map(|s| s.to_vec())
                        .unwrap_or_default()
                };
                let total_count = cc
                    .and_then(|c| c.get("totalCount"))
                    .and_then(JsonValue::as_i64)
                    .unwrap_or(raw_comments.len() as i64);
                let cc_has_next = cc
                    .and_then(|c| c.get("pageInfo"))
                    .and_then(|p| p.get("hasNextPage"))
                    .and_then(JsonValue::as_bool)
                    .unwrap_or(false);
                let line = t
                    .get("line")
                    .and_then(JsonValue::as_i64)
                    .or_else(|| t.get("originalLine").and_then(JsonValue::as_i64));
                let comments = raw_comments
                    .iter()
                    .map(|c| ThreadComment {
                        id: c
                            .get("id")
                            .and_then(JsonValue::to_text_string)
                            .unwrap_or_default(),
                        author: c
                            .get("author")
                            .and_then(|a| a.get("login"))
                            .and_then(JsonValue::as_str)
                            .filter(|s| !s.is_empty())
                            .unwrap_or("unknown")
                            .to_string(),
                        body: if include_bodies {
                            Some(
                                c.get("body")
                                    .and_then(JsonValue::as_str)
                                    .unwrap_or("")
                                    .to_string(),
                            )
                        } else {
                            None
                        },
                    })
                    .collect();
                threads.push(ReviewThread {
                    id: tid,
                    is_resolved: t
                        .get("isResolved")
                        .and_then(JsonValue::as_bool)
                        .unwrap_or(false),
                    is_outdated: t
                        .get("isOutdated")
                        .and_then(JsonValue::as_bool)
                        .unwrap_or(false),
                    path: t
                        .get("path")
                        .and_then(JsonValue::as_str)
                        .unwrap_or("")
                        .to_string(),
                    line,
                    total_count,
                    has_more_nested_comments: cc_has_next && !include_bodies,
                    comments,
                });
            }
        }
        let has_next = rt
            .and_then(|r| r.get("pageInfo"))
            .and_then(|p| p.get("hasNextPage"))
            .and_then(JsonValue::as_bool)
            .unwrap_or(false);
        if !has_next {
            let meta = pr_meta.ok_or_else(|| {
                err_simple("PR_API_ERROR", "Missing pullRequest metadata in response")
            })?;
            return Ok((viewer, meta, threads));
        }
        cursor = rt
            .and_then(|r| r.get("pageInfo"))
            .and_then(|p| p.get("endCursor"))
            .and_then(JsonValue::as_str)
            .map(str::to_string);
    }

    Err(err_blocked_before_write(
        "PR_PAGINATION_INCOMPLETE",
        format!("Review thread pagination reached --max-pages ({max_pages})"),
        Vec::new(),
    ))
}

#[derive(Debug, Clone)]
struct OpIdentity {
    key: String,
    op_hash: String,
    marker: String,
}

#[allow(clippy::too_many_arguments)]
fn compute_operation_identity(
    repo_full: &str,
    pr: u64,
    actor: &str,
    op: &str,
    target_kind: &str,
    target_id: &str,
    reviewed_sha: &str,
    mode: &str,
    event: &str,
    normalized_payload: &str,
    explicit_key: &str,
) -> OpIdentity {
    let payload_sha = sha256_utf8_hex(&normalize_text(normalized_payload));
    let canonical = JsonValue::obj(vec![
        (
            "repo".to_string(),
            JsonValue::str(repo_full.to_ascii_lowercase()),
        ),
        ("pr".to_string(), JsonValue::num_u64(pr)),
        (
            "actor".to_string(),
            JsonValue::str(actor.to_ascii_lowercase()),
        ),
        ("op".to_string(), JsonValue::str(op)),
        ("target_kind".to_string(), JsonValue::str(target_kind)),
        ("target_id".to_string(), JsonValue::str(target_id)),
        (
            "reviewed_sha".to_string(),
            JsonValue::str(reviewed_sha.to_ascii_lowercase()),
        ),
        ("mode".to_string(), JsonValue::str(mode)),
        ("event".to_string(), JsonValue::str(event)),
        ("payload_sha256".to_string(), JsonValue::str(payload_sha)),
    ])
    .to_json_string();
    let op_hash = sha256_utf8_hex(&canonical)[..16].to_string();
    let key = if explicit_key.is_empty() {
        format!("auto-{op_hash}")
    } else {
        explicit_key.to_string()
    };
    let marker = format!("<!-- b3-pr-key:{key};op={op_hash} -->");
    OpIdentity {
        key,
        op_hash,
        marker,
    }
}

#[derive(Debug, Clone)]
struct InlineCommentSpec {
    path: String,
    line: i64,
    side: String,
    body: String,
}

impl InlineCommentSpec {
    fn to_json(&self) -> JsonValue {
        JsonValue::obj(vec![
            ("path".to_string(), JsonValue::str(&self.path)),
            ("line".to_string(), JsonValue::num_i64(self.line)),
            ("side".to_string(), JsonValue::str(&self.side)),
            ("body".to_string(), JsonValue::str(&self.body)),
        ])
    }
}

fn verify_inline_comments_match(expected: &[InlineCommentSpec], remote: &[JsonValue]) -> bool {
    if expected.is_empty() {
        return true;
    }
    if remote.len() != expected.len() {
        return false;
    }
    let mut returned_keys = BTreeSet::new();
    for rc in remote {
        let p = rc.get("path").and_then(JsonValue::as_str).unwrap_or("");
        let line = rc
            .get("line")
            .and_then(JsonValue::as_i64)
            .filter(|&n| n != 0)
            .or_else(|| rc.get("original_line").and_then(JsonValue::as_i64))
            .unwrap_or(0);
        let side = rc
            .get("side")
            .and_then(JsonValue::as_str)
            .unwrap_or("")
            .to_ascii_uppercase();
        let body = normalize_text(rc.get("body").and_then(JsonValue::as_str).unwrap_or(""));
        returned_keys.insert(format!("{p}:{line}:{side}:{body}"));
    }
    expected.iter().all(|ic| {
        let key = format!(
            "{}:{}:{}:{}",
            ic.path,
            ic.line,
            ic.side,
            normalize_text(&ic.body)
        );
        returned_keys.contains(&key)
    })
}

struct VerifyRemoteSpec<'a> {
    kind: &'a str,
    repo: &'a str,
    pr: u64,
    viewer: &'a str,
    created_id: &'a str,
    thread_id: &'a str,
    expected_head: &'a str,
    expected_body: Option<&'a str>,
    expected_body_sha256: &'a str,
    marker: &'a str,
    event: &'a str,
    expected_inline: &'a [InlineCommentSpec],
}

struct VerifyRemoteOutcome {
    found: bool,
    ok: bool,
    is_resolved: bool,
    post_state: String,
    post_head: String,
    reason: String,
}

fn event_to_review_state(event: &str) -> &'static str {
    match event {
        "COMMENT" => "COMMENTED",
        "APPROVE" => "APPROVED",
        "REQUEST_CHANGES" => "CHANGES_REQUESTED",
        _ => "",
    }
}

fn verify_remote_object(
    spec: &VerifyRemoteSpec<'_>,
    max_pages: u64,
) -> Result<VerifyRemoteOutcome, PrExit> {
    let actor_lower = spec.viewer.to_ascii_lowercase();
    let body_matches = |remote_body: &str| -> bool {
        if !spec.marker.is_empty() && !remote_body.contains(spec.marker) {
            return false;
        }
        let stripped = strip_markers(remote_body);
        if let Some(exp) = spec.expected_body {
            if stripped != strip_markers(exp) {
                return false;
            }
        }
        spec.expected_body_sha256.is_empty()
            || sha256_utf8_hex(&stripped) == spec.expected_body_sha256
    };
    let (owner, name) = spec.repo.split_once('/').unwrap_or(("", ""));

    match spec.kind {
        "review_thread_reply" => {
            let q = "query($owner: String!, $repo: String!, $pr: Int!, $threadId: ID!, $commentId: ID!) {
      repository(owner: $owner, name: $repo) { pullRequest(number: $pr) { state headRefOid } }
      thread: node(id: $threadId) { ... on PullRequestReviewThread { id isResolved pullRequest { number repository { nameWithOwner } } } }
      comment: node(id: $commentId) { ... on PullRequestReviewComment { id author { login } body pullRequest { number } } }
    }";
            let vars = JsonValue::obj(vec![
                ("owner".to_string(), JsonValue::str(owner)),
                ("repo".to_string(), JsonValue::str(name)),
                ("pr".to_string(), JsonValue::num_u64(spec.pr)),
                ("threadId".to_string(), JsonValue::str(spec.thread_id)),
                ("commentId".to_string(), JsonValue::str(spec.created_id)),
            ]);
            let d = gh_graphql(q, vars)?;
            let post_state = d
                .get("repository")
                .and_then(|r| r.get("pullRequest"))
                .and_then(|p| p.get("state"))
                .and_then(JsonValue::as_str)
                .unwrap_or("")
                .to_string();
            let post_head = d
                .get("repository")
                .and_then(|r| r.get("pullRequest"))
                .and_then(|p| p.get("headRefOid"))
                .and_then(JsonValue::as_str)
                .unwrap_or("")
                .to_ascii_lowercase();
            let Some(c) = d.get("comment").filter(|v| !matches!(v, JsonValue::Null)) else {
                return Ok(VerifyRemoteOutcome {
                    found: false,
                    ok: false,
                    is_resolved: false,
                    post_state,
                    post_head,
                    reason: "comment_not_found".to_string(),
                });
            };
            let t = d.get("thread").filter(|v| !matches!(v, JsonValue::Null));
            let t_owner = t
                .and_then(|tv| tv.get("pullRequest"))
                .and_then(|p| p.get("repository"))
                .and_then(|r| r.get("nameWithOwner"))
                .and_then(JsonValue::as_str)
                .unwrap_or("")
                .to_ascii_lowercase();
            let cid = c
                .get("id")
                .and_then(JsonValue::to_text_string)
                .unwrap_or_default();
            let c_author = c
                .get("author")
                .and_then(|a| a.get("login"))
                .and_then(JsonValue::as_str)
                .unwrap_or("")
                .to_ascii_lowercase();
            let c_pr = c
                .get("pullRequest")
                .and_then(|p| p.get("number"))
                .and_then(JsonValue::as_i64)
                .unwrap_or(0);
            let t_id = t
                .and_then(|tv| tv.get("id"))
                .and_then(JsonValue::to_text_string)
                .unwrap_or_default();
            let c_body = c.get("body").and_then(JsonValue::as_str).unwrap_or("");
            let ok = cid == spec.created_id
                && c_author == actor_lower
                && c_pr == spec.pr as i64
                && t.is_some()
                && t_id == spec.thread_id
                && (t_owner.is_empty() || t_owner == spec.repo.to_ascii_lowercase())
                && body_matches(c_body);
            Ok(VerifyRemoteOutcome {
                found: true,
                ok,
                is_resolved: false,
                post_state,
                post_head,
                reason: if ok {
                    "verified".to_string()
                } else {
                    "content_or_target_mismatch".to_string()
                },
            })
        }
        "issue_comment" => {
            let v_res = gh_rest_get(
                &format!("repos/{}/issues/comments/{}", spec.repo, spec.created_id),
                true,
            )?;
            let post_header = fetch_pr_header(owner, name, spec.pr)?;
            let GhResponse::Data(Some(c)) = v_res else {
                return Ok(VerifyRemoteOutcome {
                    found: false,
                    ok: false,
                    is_resolved: false,
                    post_state: post_header.state,
                    post_head: post_header.head_sha,
                    reason: "comment_not_found".to_string(),
                });
            };
            let cid = c
                .get("id")
                .and_then(JsonValue::to_text_string)
                .unwrap_or_default();
            let user_login = c
                .get("user")
                .and_then(|u| u.get("login"))
                .and_then(JsonValue::as_str)
                .unwrap_or("")
                .to_ascii_lowercase();
            let issue_url = c.get("issue_url").and_then(JsonValue::as_str).unwrap_or("");
            let c_body = c.get("body").and_then(JsonValue::as_str).unwrap_or("");
            let ok = cid == spec.created_id
                && user_login == actor_lower
                && issue_url.ends_with(&format!("/issues/{}", spec.pr))
                && body_matches(c_body);
            Ok(VerifyRemoteOutcome {
                found: true,
                ok,
                is_resolved: false,
                post_state: post_header.state,
                post_head: post_header.head_sha,
                reason: if ok {
                    "verified".to_string()
                } else {
                    "content_or_target_mismatch".to_string()
                },
            })
        }
        "pull_review" => {
            let v_res = gh_rest_get(
                &format!(
                    "repos/{}/pulls/{}/reviews/{}",
                    spec.repo, spec.pr, spec.created_id
                ),
                true,
            )?;
            let post_header = fetch_pr_header(owner, name, spec.pr)?;
            let GhResponse::Data(Some(r)) = v_res else {
                return Ok(VerifyRemoteOutcome {
                    found: false,
                    ok: false,
                    is_resolved: false,
                    post_state: post_header.state,
                    post_head: post_header.head_sha,
                    reason: "review_not_found".to_string(),
                });
            };
            let rev_state = r
                .get("state")
                .and_then(JsonValue::as_str)
                .unwrap_or("")
                .to_ascii_uppercase();
            let state_ok = rev_state != "DISMISSED"
                && (rev_state == event_to_review_state(spec.event) || rev_state == spec.event);
            let commit_ok = r
                .get("commit_id")
                .and_then(JsonValue::as_str)
                .unwrap_or("")
                .eq_ignore_ascii_case(spec.expected_head);
            let rev_comments = if !spec.expected_inline.is_empty() {
                fetch_rest_paginated(
                    &format!(
                        "repos/{}/pulls/{}/reviews/{}/comments",
                        spec.repo, spec.pr, spec.created_id
                    ),
                    max_pages,
                )?
            } else {
                Vec::new()
            };
            let inline_ok = verify_inline_comments_match(spec.expected_inline, &rev_comments);
            let rid = r
                .get("id")
                .and_then(JsonValue::to_text_string)
                .unwrap_or_default();
            let user_login = r
                .get("user")
                .and_then(|u| u.get("login"))
                .and_then(JsonValue::as_str)
                .unwrap_or("")
                .to_ascii_lowercase();
            let r_body = r.get("body").and_then(JsonValue::as_str).unwrap_or("");
            let ok = rid == spec.created_id
                && user_login == actor_lower
                && state_ok
                && commit_ok
                && body_matches(r_body)
                && inline_ok;
            let reason = if ok {
                "verified".to_string()
            } else {
                format!(
                    "review_mismatch(state={rev_state},commitOk={commit_ok},inlineOk={inline_ok})"
                )
            };
            Ok(VerifyRemoteOutcome {
                found: true,
                ok,
                is_resolved: false,
                post_state: post_header.state,
                post_head: post_header.head_sha,
                reason,
            })
        }
        "resolve_thread" => {
            let q = "query($owner: String!, $repo: String!, $pr: Int!, $threadId: ID!) {
      repository(owner: $owner, name: $repo) { pullRequest(number: $pr) { state headRefOid } }
      node(id: $threadId) { ... on PullRequestReviewThread { id isResolved pullRequest { number repository { nameWithOwner } } } }
    }";
            let vars = JsonValue::obj(vec![
                ("owner".to_string(), JsonValue::str(owner)),
                ("repo".to_string(), JsonValue::str(name)),
                ("pr".to_string(), JsonValue::num_u64(spec.pr)),
                ("threadId".to_string(), JsonValue::str(spec.thread_id)),
            ]);
            let d = gh_graphql(q, vars)?;
            let post_state = d
                .get("repository")
                .and_then(|r| r.get("pullRequest"))
                .and_then(|p| p.get("state"))
                .and_then(JsonValue::as_str)
                .unwrap_or("")
                .to_string();
            let post_head = d
                .get("repository")
                .and_then(|r| r.get("pullRequest"))
                .and_then(|p| p.get("headRefOid"))
                .and_then(JsonValue::as_str)
                .unwrap_or("")
                .to_ascii_lowercase();
            let Some(t) = d.get("node").filter(|v| !matches!(v, JsonValue::Null)) else {
                return Ok(VerifyRemoteOutcome {
                    found: false,
                    ok: false,
                    is_resolved: false,
                    post_state,
                    post_head,
                    reason: "thread_not_found".to_string(),
                });
            };
            let t_id = t
                .get("id")
                .and_then(JsonValue::to_text_string)
                .unwrap_or_default();
            let is_resolved = t
                .get("isResolved")
                .and_then(JsonValue::as_bool)
                .unwrap_or(false);
            let t_owner = t
                .get("pullRequest")
                .and_then(|p| p.get("repository"))
                .and_then(|r| r.get("nameWithOwner"))
                .and_then(JsonValue::as_str)
                .unwrap_or("")
                .to_ascii_lowercase();
            let t_pr = t
                .get("pullRequest")
                .and_then(|p| p.get("number"))
                .and_then(JsonValue::as_i64)
                .unwrap_or(0);
            let ok = t_id == spec.thread_id
                && is_resolved
                && t_owner == spec.repo.to_ascii_lowercase()
                && t_pr == spec.pr as i64;
            Ok(VerifyRemoteOutcome {
                found: true,
                ok,
                is_resolved,
                post_state,
                post_head,
                reason: if ok {
                    "verified".to_string()
                } else {
                    "thread_not_resolved_or_mismatch".to_string()
                },
            })
        }
        other => Err(err_simple(
            "PR_API_ERROR",
            format!("Unknown verification kind: {other}"),
        )),
    }
}

struct IdemCandidate {
    id: String,
    kind: String,
    author: String,
    body: String,
}

enum IdemStatus {
    None,
    Collision { existing_id: String },
    RemoteMismatch { existing_id: String, reason: String },
    Match { existing_id: String },
}

fn check_idempotency_with_revalidation<F>(
    items: &[IdemCandidate],
    viewer_login: &str,
    identity: &OpIdentity,
    mut revalidate: F,
) -> Result<IdemStatus, PrExit>
where
    F: FnMut(&IdemCandidate, &str) -> Result<VerifyRemoteOutcome, PrExit>,
{
    let actor_lower = viewer_login.to_ascii_lowercase();
    for item in items {
        if item.author.to_ascii_lowercase() != actor_lower {
            continue;
        }
        for (_, _, found_key, found_op) in scan_b3_markers(&item.body) {
            let key_match = found_key == identity.key;
            let op_match = !found_op.is_empty() && found_op == identity.op_hash;
            if key_match && (found_op.is_empty() || !op_match) {
                return Ok(IdemStatus::Collision {
                    existing_id: item.id.clone(),
                });
            }
            if key_match || op_match {
                let check = revalidate(item, &identity.marker)?;
                if check.ok {
                    return Ok(IdemStatus::Match {
                        existing_id: item.id.clone(),
                    });
                }
                let reason = if check.reason.is_empty() {
                    "remote_object_modified".to_string()
                } else {
                    check.reason
                };
                return Ok(IdemStatus::RemoteMismatch {
                    existing_id: item.id.clone(),
                    reason,
                });
            }
        }
    }
    Ok(IdemStatus::None)
}

fn parse_hunk_header(line: &str) -> Option<(i64, i64, i64, i64)> {
    let rest = line.strip_prefix("@@ -")?;
    let space1 = rest.find(' ')?;
    let left_part = &rest[..space1];
    let after_left = rest[space1 + 1..].strip_prefix('+')?;
    let space2 = after_left.find(" @@")?;
    let right_part = &after_left[..space2];

    let parse_span = |part: &str| -> Option<(i64, i64)> {
        if let Some((a, b)) = part.split_once(',') {
            if a.is_empty()
                || b.is_empty()
                || !a.bytes().all(|c| c.is_ascii_digit())
                || !b.bytes().all(|c| c.is_ascii_digit())
            {
                return None;
            }
            Some((a.parse().ok()?, b.parse().ok()?))
        } else {
            if part.is_empty() || !part.bytes().all(|c| c.is_ascii_digit()) {
                return None;
            }
            Some((part.parse().ok()?, 1))
        }
    };
    let (l_start, l_count) = parse_span(left_part)?;
    let (r_start, r_count) = parse_span(right_part)?;
    Some((l_start, l_count, r_start, r_count))
}

struct DiffAnchors {
    right_lines: BTreeSet<i64>,
    left_lines: BTreeSet<i64>,
}

fn parse_unified_diff_anchors(patch: Option<&str>) -> Result<DiffAnchors, &'static str> {
    let Some(raw) = patch else {
        return Err("missing_or_empty_patch");
    };
    if raw.trim().is_empty() {
        return Err("missing_or_empty_patch");
    }
    let mut lines: Vec<&str> = raw
        .split('\n')
        .map(|l| l.strip_suffix('\r').unwrap_or(l))
        .collect();
    if matches!(lines.last(), Some(&"")) {
        lines.pop();
    }
    let mut right_lines = BTreeSet::new();
    let mut left_lines = BTreeSet::new();
    let mut saw_hunk = false;
    let mut in_hunk = false;
    let mut left_line = 0i64;
    let mut right_line = 0i64;
    let mut exp_left = 0i64;
    let mut exp_right = 0i64;
    let mut seen_left = 0i64;
    let mut seen_right = 0i64;

    for raw_line in lines {
        if let Some((ls, el, rs, er)) = parse_hunk_header(raw_line) {
            if in_hunk && (seen_left != exp_left || seen_right != exp_right) {
                return Err("truncated_or_count_mismatch");
            }
            saw_hunk = true;
            in_hunk = true;
            left_line = ls;
            exp_left = el;
            right_line = rs;
            exp_right = er;
            seen_left = 0;
            seen_right = 0;
            continue;
        }
        if !in_hunk {
            const PREAMBLES: &[&str] = &[
                "diff --git ",
                "index ",
                "--- ",
                "+++ ",
                "new file",
                "deleted file",
                "old mode",
                "new mode",
                "rename ",
                "similarity ",
            ];
            if PREAMBLES.iter().any(|p| raw_line.starts_with(p)) {
                continue;
            }
            return Err("malformed_diff_preamble");
        }
        if raw_line.starts_with('+') {
            right_lines.insert(right_line);
            right_line += 1;
            seen_right += 1;
        } else if raw_line.starts_with('-') {
            left_lines.insert(left_line);
            left_line += 1;
            seen_left += 1;
        } else if raw_line.starts_with(' ') {
            left_lines.insert(left_line);
            right_lines.insert(right_line);
            left_line += 1;
            right_line += 1;
            seen_left += 1;
            seen_right += 1;
        } else if raw_line.starts_with("\\ No newline at end of file") {
            continue;
        } else {
            return Err("malformed_hunk_line");
        }
        if seen_left > exp_left || seen_right > exp_right {
            return Err("hunk_line_count_overflow");
        }
    }
    if !saw_hunk || (in_hunk && (seen_left != exp_left || seen_right != exp_right)) {
        return Err("truncated_or_count_mismatch");
    }
    Ok(DiffAnchors {
        right_lines,
        left_lines,
    })
}

fn is_b3_checkpoint_path(p: &str) -> bool {
    crate::fs::test_checkpoint_path(&p.to_ascii_lowercase())
}

fn assert_clean_index_and_working_tree(repo_root: &Path) -> Result<(), PrExit> {
    let no_env: [(&str, &str); 0] = [];
    let st_res = run_git(
        repo_root,
        &["status", "--porcelain=v1", "-z", "--untracked-files=all"],
        &no_env,
        None,
    )
    .map_err(|_| {
        err_blocked_before_write(
            "PR_VERIFY_REQUIRED",
            format!(
                "Unable to inspect working tree cleanliness in {} for exact-commit verification",
                repo_root.display()
            ),
            Vec::new(),
        )
    })?;
    if st_res.exit_code != 0 {
        return Err(err_blocked_before_write(
            "PR_VERIFY_REQUIRED",
            format!(
                "Unable to inspect working tree cleanliness in {} for exact-commit verification",
                repo_root.display()
            ),
            Vec::new(),
        ));
    }
    let mut dirty = Vec::new();
    let tokens: Vec<&[u8]> = st_res.stdout.split(|&b| b == 0).collect();
    let mut i = 0usize;
    while i < tokens.len() {
        let entry_bytes = tokens[i];
        i += 1;
        if entry_bytes.is_empty() {
            continue;
        }
        let Ok(entry) = std::str::from_utf8(entry_bytes) else {
            return Err(err_blocked_before_write(
                "PR_VERIFY_REQUIRED",
                "Malformed git status output during exact-commit verification",
                Vec::new(),
            ));
        };
        if entry.chars().count() < 4 {
            return Err(err_blocked_before_write(
                "PR_VERIFY_REQUIRED",
                "Malformed git status output during exact-commit verification",
                Vec::new(),
            ));
        }
        let xy = &entry[..2];
        let mut rel = entry[3..].replace('\\', "/");
        while let Some(stripped) = rel.strip_prefix("./") {
            rel = stripped.to_string();
        }
        let mut orig = String::new();
        if (xy.contains('R') || xy.contains('C')) && i < tokens.len() {
            orig = String::from_utf8_lossy(tokens[i]).replace('\\', "/");
            while let Some(stripped) = orig.strip_prefix("./") {
                orig = stripped.to_string();
            }
            i += 1;
        }
        if !rel.is_empty() && !is_b3_checkpoint_path(&rel) {
            dirty.push(rel);
        } else if !orig.is_empty() && !is_b3_checkpoint_path(&orig) {
            dirty.push(orig);
        }
    }
    if !dirty.is_empty() {
        let mut preview_parts: Vec<String> = dirty
            .iter()
            .take(5)
            .map(|p| sanitize_untrusted_text(p))
            .collect();
        let mut preview = preview_parts.join(", ");
        if dirty.len() > 5 {
            preview.push_str(&format!(" (+{} more)", dirty.len() - 5));
        }
        let _ = &mut preview_parts;
        let dirty_vals: Vec<JsonValue> = dirty.iter().take(20).map(JsonValue::str).collect();
        return Err(err_blocked_before_write(
            "PR_VERIFY_REQUIRED",
            format!("Uncommitted or untracked working-tree/index changes absent from PR HEAD ({preview})"),
            vec![("dirty_paths".to_string(), JsonValue::Array(dirty_vals))],
        ));
    }
    Ok(())
}

fn assert_inside_dot_b3(repo_root: &Path, receipt_full_path: &Path) -> Result<String, PrExit> {
    let dot_b3_dir = repo_root.join(".b3");
    let dot_b3_ok = match (fs::symlink_metadata(&dot_b3_dir), fs::metadata(&dot_b3_dir)) {
        (Ok(lst), Ok(st)) => {
            !lst.file_type().is_symlink()
                && !is_reparse_or_symlink(&dot_b3_dir)
                && lst.is_dir()
                && st.is_dir()
        }
        _ => false,
    };
    if !dot_b3_ok {
        return Err(err_blocked_before_write(
            "PR_VERIFY_REQUIRED",
            format!(
                "Verification receipt must reside inside repository .b3/ directory ({})",
                dot_b3_dir.display()
            ),
            Vec::new(),
        ));
    }
    let real_b3 = canonicalize_clean(&dot_b3_dir).map_err(|_| {
        err_blocked_before_write(
            "PR_VERIFY_REQUIRED",
            format!(
                "Verification receipt must reside inside repository .b3/ directory ({})",
                dot_b3_dir.display()
            ),
            Vec::new(),
        )
    })?;
    let real_receipt = canonicalize_clean(receipt_full_path).map_err(|_| {
        err_blocked_before_write(
            "PR_VERIFY_REQUIRED",
            format!(
                "Verification receipt must reside inside repository .b3/ directory ({})",
                dot_b3_dir.display()
            ),
            Vec::new(),
        )
    })?;
    let rel_norm = if cfg!(windows) {
        let b_str = real_b3.to_string_lossy().replace('\\', "/");
        let r_str = real_receipt.to_string_lossy().replace('\\', "/");
        let prefix_ok = r_str
            .get(..b_str.len())
            .is_some_and(|p| p.eq_ignore_ascii_case(&b_str));
        let tail = r_str.get(b_str.len()..).unwrap_or("");
        if !prefix_ok || !tail.starts_with('/') {
            None
        } else {
            Some(tail[1..].to_string())
        }
    } else {
        real_receipt
            .strip_prefix(&real_b3)
            .ok()
            .map(|p| p.to_string_lossy().replace('\\', "/"))
            .filter(|s| !s.is_empty())
    };
    let Some(rel) = rel_norm else {
        return Err(err_blocked_before_write(
            "PR_VERIFY_REQUIRED",
            format!(
                "Verification receipt must reside inside repository .b3/ directory ({})",
                dot_b3_dir.display()
            ),
            Vec::new(),
        ));
    };
    if rel.is_empty()
        || rel == "."
        || rel.starts_with("..")
        || Path::new(&rel).is_absolute()
        || rel.contains(':')
    {
        return Err(err_blocked_before_write(
            "PR_VERIFY_REQUIRED",
            format!(
                "Verification receipt must reside inside repository .b3/ directory ({})",
                dot_b3_dir.display()
            ),
            Vec::new(),
        ));
    }
    Ok(format!(".b3/{rel}"))
}

fn run_canonical_verify_check(
    repo_root: &Path,
    receipt_full_path: &Path,
    expected_head: &str,
    expected_cmd: &str,
    required_paths: &[String],
) -> Result<String, PrExit> {
    let no_env: [(&str, &str); 0] = [];
    let exp_ref = format!("{expected_head}^{{commit}}");
    let head_res = run_git(
        repo_root,
        &["rev-parse", "--verify", &exp_ref],
        &no_env,
        None,
    );
    let local_res = run_git(
        repo_root,
        &["rev-parse", "--verify", "HEAD^{commit}"],
        &no_env,
        None,
    );
    let (Ok(hr), Ok(lr)) = (head_res, local_res) else {
        return Err(err_blocked_before_write(
            "PR_VERIFY_REQUIRED",
            format!(
                "Unable to verify local Git HEAD or remote commit {expected_head} in {}",
                repo_root.display()
            ),
            Vec::new(),
        ));
    };
    if hr.exit_code != 0 || lr.exit_code != 0 {
        return Err(err_blocked_before_write(
            "PR_VERIFY_REQUIRED",
            format!(
                "Unable to verify local Git HEAD or remote commit {expected_head} in {}",
                repo_root.display()
            ),
            Vec::new(),
        ));
    }
    let local_head = String::from_utf8_lossy(&lr.stdout)
        .trim()
        .to_ascii_lowercase();
    if local_head != expected_head {
        return Err(err_blocked_before_write(
            "PR_VERIFY_REQUIRED",
            format!(
                "Local repository HEAD ({local_head}) does not match expected remote PR HEAD ({expected_head})"
            ),
            Vec::new(),
        ));
    }

    let rel_receipt = assert_inside_dot_b3(repo_root, receipt_full_path)?;
    let req_csv = required_paths.join(",");
    let repo_root_str = repo_root.to_string_lossy();
    let vc_res = verify_check(
        &repo_root_str,
        &rel_receipt,
        expected_cmd,
        &req_csv,
        "",
        expected_head,
        true,
    );
    let msg = match vc_res {
        Ok((out, 0)) if out.contains("VERIFY_VALID:") => out,
        Ok((out, code)) => {
            let snippet = truncate_chars(&sanitize_untrusted_text(out.trim()), 260);
            return Err(err_blocked_before_write(
                "PR_VERIFY_REQUIRED",
                format!("Canonical b3 guard verify-check failed (exit {code}): {snippet}"),
                Vec::new(),
            ));
        }
        Err(e) => {
            let snippet = truncate_chars(&sanitize_untrusted_text(e.message.trim()), 260);
            return Err(err_blocked_before_write(
                "PR_VERIFY_REQUIRED",
                format!(
                    "Canonical b3 guard verify-check failed (exit {}): {snippet}",
                    e.code
                ),
                Vec::new(),
            ));
        }
    };

    assert_clean_index_and_working_tree(repo_root)?;
    Ok(msg.lines().next().unwrap_or("").to_string())
}

struct ResolveEvidence {
    basis: String,
    primary_thread_id: String,
    target_path: String,
    fixed_paths: Vec<String>,
    checked_command: String,
    receipt_full_path: PathBuf,
}

fn parse_resolve_evidence(
    evidence_path: &str,
    repo_root: &Path,
    repo_full: &str,
    pr_number: u64,
    expected_head: &str,
    thread_id: &str,
    fix_commit: &str,
) -> Result<ResolveEvidence, PrExit> {
    let raw = read_safe_input_file(evidence_path, "--evidence-file", MAX_FILE_BYTES)?;
    let ev = parse_json(&raw).map_err(|_| {
        err_blocked_before_write(
            "PR_VERIFY_REQUIRED",
            "--evidence-file is not valid JSON",
            Vec::new(),
        )
    })?;
    let blocked = |msg: String| err_blocked_before_write("PR_VERIFY_REQUIRED", msg, Vec::new());
    if !ev.is_object()
        || ev.get("schema").and_then(JsonValue::as_str) != Some("b3-pr-verify-evidence-v1")
    {
        return Err(blocked(
            "Evidence schema must be b3-pr-verify-evidence-v1".to_string(),
        ));
    }
    let ev_repo = ev.get("repo").and_then(JsonValue::as_str).unwrap_or("");
    if !ev_repo.eq_ignore_ascii_case(repo_full) {
        return Err(blocked(format!(
            "Evidence repo ({ev_repo}) does not match {repo_full}"
        )));
    }
    let ev_pr = ev.get("pr").and_then(JsonValue::as_i64).unwrap_or(-1);
    if ev_pr != pr_number as i64 {
        return Err(blocked(format!(
            "Evidence PR ({}) does not match #{pr_number}",
            ev.get("pr")
                .and_then(JsonValue::to_text_string)
                .unwrap_or_else(|| "undefined".to_string())
        )));
    }
    let ev_head = ev.get("head_sha").and_then(JsonValue::as_str).unwrap_or("");
    if !ev_head.eq_ignore_ascii_case(expected_head) {
        return Err(blocked(format!(
            "Evidence head_sha ({ev_head}) does not match expected HEAD ({expected_head})"
        )));
    }
    let ev_tid = ev
        .get("thread_id")
        .and_then(JsonValue::to_text_string)
        .unwrap_or_default();
    if ev_tid != thread_id {
        return Err(blocked(format!(
            "Evidence thread_id ({ev_tid}) does not match {thread_id}"
        )));
    }
    let ev_fix = ev
        .get("fix_commit")
        .and_then(JsonValue::as_str)
        .unwrap_or("");
    if !ev_fix.eq_ignore_ascii_case(fix_commit) {
        return Err(blocked(format!(
            "Evidence fix_commit ({ev_fix}) does not match {fix_commit}"
        )));
    }
    let basis = ev
        .get("resolution_basis")
        .and_then(JsonValue::as_str)
        .unwrap_or("")
        .to_string();
    if !matches!(
        basis.as_str(),
        "CONFIRMED_FIXED" | "ALREADY_FIXED" | "DUPLICATE_FIXED"
    ) {
        return Err(blocked(format!(
            "Invalid evidence resolution_basis ({basis})"
        )));
    }
    let primary_thread_id = if basis == "DUPLICATE_FIXED" {
        ev.get("primary_thread_id")
            .and_then(JsonValue::as_str)
            .unwrap_or("")
            .to_string()
    } else {
        String::new()
    };
    if basis == "DUPLICATE_FIXED"
        && (!is_valid_id(&primary_thread_id) || primary_thread_id == thread_id)
    {
        return Err(blocked(
            "DUPLICATE_FIXED requires a distinct valid primary_thread_id".to_string(),
        ));
    }
    let target_raw = ev
        .get("target_path")
        .and_then(JsonValue::as_str)
        .unwrap_or("")
        .trim();
    let target_path = validate_rel_path(target_raw, "evidence.target_path")?;
    let mut fixed_paths = Vec::new();
    if let Some(arr) = ev.get("fixed_paths").and_then(JsonValue::as_array) {
        for (i, item) in arr.iter().enumerate() {
            let p_str = item.as_str().unwrap_or("").trim();
            fixed_paths.push(validate_rel_path(
                p_str,
                &format!("evidence.fixed_paths[{i}]"),
            )?);
        }
    }
    let checked_command = ev
        .get("checked_command")
        .and_then(JsonValue::as_str)
        .unwrap_or("")
        .trim()
        .to_string();
    let summary = ev
        .get("summary")
        .and_then(JsonValue::as_str)
        .unwrap_or("")
        .trim();
    if checked_command.is_empty() || summary.chars().count() < 10 {
        return Err(blocked(
            "Evidence requires non-empty checked_command and descriptive summary (>=10 chars)"
                .to_string(),
        ));
    }
    let receipt_rel = ev
        .get("verify_receipt_path")
        .and_then(JsonValue::as_str)
        .unwrap_or("")
        .trim();
    if receipt_rel.is_empty() {
        return Err(blocked("Evidence requires verify_receipt_path".to_string()));
    }
    validate_raw_path_syntax(receipt_rel, "verify_receipt_path", true)?;
    let receipt_cand = if Path::new(receipt_rel).is_absolute() {
        crate::fs::resolve_unresolved_path(repo_root, receipt_rel)
    } else {
        repo_root.join(receipt_rel)
    };
    let receipt_full_path = validate_safe_path(
        &receipt_cand.to_string_lossy(),
        "verify_receipt_path",
        false,
        true,
        MAX_FILE_BYTES,
    )?;
    assert_inside_dot_b3(repo_root, &receipt_full_path)?;
    Ok(ResolveEvidence {
        basis,
        primary_thread_id,
        target_path,
        fixed_paths,
        checked_command,
        receipt_full_path,
    })
}

enum PrepareResult<T> {
    EarlyEmit {
        payload: JsonValue,
        audit_record: Option<Vec<(String, JsonValue)>>,
    },
    Proceed {
        state: T,
        pending_meta: Vec<(String, JsonValue)>,
        extra_ids: Vec<(String, JsonValue)>,
    },
}

struct MutationResult {
    created_id: Option<String>,
    require_id: bool,
}

#[allow(clippy::too_many_arguments)]
fn execute_guarded_mutation<T, P, B, M, V, S>(
    state_path: &Path,
    repo: &RepoSlug,
    pr_number: u64,
    expected_head: &str,
    action: &str,
    max_pages: u64,
    prepare: P,
    before_mutate: B,
    mutate: M,
    verify_remote_fn: V,
    on_success_payload: S,
) -> Result<PrExit, PrExit>
where
    P: FnOnce(&PrHeader) -> Result<PrepareResult<T>, PrExit>,
    B: FnOnce() -> Result<(), PrExit>,
    M: FnOnce(&T, &PrHeader) -> Result<MutationResult, PrExit>,
    V: FnOnce(&T, &PrHeader, &str, u64) -> Result<VerifyRemoteOutcome, PrExit>,
    S: FnOnce(&T, &PrHeader, Option<&str>, &VerifyRemoteOutcome) -> JsonValue,
{
    with_state_lock(state_path, action, || {
        let records = read_state_records(state_path)?;
        let pending = get_unresolved_pending_records(&records, &repo.full, pr_number);
        if !pending.is_empty() {
            let statuses: Vec<&str> = pending
                .iter()
                .map(|r| r.get("status").and_then(JsonValue::as_str).unwrap_or(""))
                .collect();
            return Err(err_blocked_before_write(
                "PR_RECONCILIATION_REQUIRED",
                format!(
                    "Unresolved prior operation(s) ({}) on {}#{pr_number} require reconciliation via reconcile subcommand",
                    statuses.join(", "),
                    repo.full
                ),
                vec![("pending_records".to_string(), JsonValue::Array(pending))],
            ));
        }

        let header = fetch_pr_header(&repo.owner, &repo.name, pr_number)?;
        assert_open_and_fresh_head(&header, expected_head)?;

        let prep = match prepare(&header)? {
            PrepareResult::EarlyEmit {
                payload,
                audit_record,
            } => {
                if let Some(rec) = audit_record {
                    let _ = append_state_record(state_path, rec, false);
                }
                return Ok(pr_emit(payload, EXIT_OK));
            }
            PrepareResult::Proceed {
                state,
                pending_meta,
                extra_ids,
            } => (state, pending_meta, extra_ids),
        };
        let (prep_state, pending_meta, extra_ids) = prep;

        let recheck_header = fetch_pr_header(&repo.owner, &repo.name, pr_number)?;
        assert_open_and_fresh_head(&recheck_header, expected_head)?;
        before_mutate()?;

        let op_id = format!("{action}-{}", unique_op_hex8());
        let mut base_pending: Vec<(String, JsonValue)> = vec![
            ("op_id".to_string(), JsonValue::str(&op_id)),
            ("action".to_string(), JsonValue::str(action)),
            ("status".to_string(), JsonValue::str("PENDING")),
            ("repo".to_string(), JsonValue::str(&repo.full)),
            ("pr".to_string(), JsonValue::num_u64(pr_number)),
            ("actor".to_string(), JsonValue::str(&header.viewer)),
            ("reviewed_sha".to_string(), JsonValue::str(expected_head)),
        ];
        base_pending.extend(pending_meta);
        append_state_record(state_path, base_pending.clone(), true)?;

        let record_unverified = |created_id: Option<&str>, reason: &str| -> PrExit {
            let mut rec = with_replaced_status(&base_pending, "PR_POST_WRITE_UNVERIFIED");
            rec.push(("reconciliation_required".to_string(), JsonValue::Bool(true)));
            rec.push((
                "created_id".to_string(),
                created_id.map_or(JsonValue::Null, JsonValue::str),
            ));
            rec.push(("detail".to_string(), JsonValue::str(reason)));
            let _ = append_state_record(state_path, rec, false);

            let mut extra = vec![
                ("outcome".to_string(), JsonValue::str("mutated_unverified")),
                ("mutated".to_string(), JsonValue::Bool(true)),
                ("reconciliation_required".to_string(), JsonValue::Bool(true)),
                ("op_id".to_string(), JsonValue::str(&op_id)),
            ];
            if let Some(cid) = created_id {
                extra.push(("created_id".to_string(), JsonValue::str(cid)));
            }
            extra.extend(extra_ids.clone());
            pr_fail(
                "PR_POST_WRITE_UNVERIFIED",
                format!("Post-write step interrupted ({reason}); run reconcile before retrying"),
                EXIT_ERROR,
                extra,
            )
        };

        let mut_res = match mutate(&prep_state, &header) {
            Ok(mr) => mr,
            Err(err) => {
                if is_post_write_status(&err) {
                    return Err(err);
                }
                let reason = format_exit_reason(&err);
                return Err(record_unverified(None, &reason));
            }
        };
        let created_id = mut_res.created_id.filter(|s| !s.is_empty());
        if mut_res.require_id && created_id.is_none() {
            let mut rec = with_replaced_status(&base_pending, "PR_POST_WRITE_UNVERIFIED");
            rec.push(("reconciliation_required".to_string(), JsonValue::Bool(true)));
            rec.push(("detail".to_string(), JsonValue::str("missing_created_id")));
            let _ = append_state_record(state_path, rec, false);
            let mut extra = vec![
                ("outcome".to_string(), JsonValue::str("mutated_unverified")),
                ("mutated".to_string(), JsonValue::Bool(true)),
                ("reconciliation_required".to_string(), JsonValue::Bool(true)),
                ("op_id".to_string(), JsonValue::str(&op_id)),
            ];
            extra.extend(extra_ids.clone());
            return Err(pr_fail(
                "PR_POST_WRITE_UNVERIFIED",
                format!("{action} did not return a created object ID"),
                EXIT_ERROR,
                extra,
            ));
        }

        let cid_str = created_id.as_deref().unwrap_or("");
        let v_res = match verify_remote_fn(&prep_state, &header, cid_str, max_pages) {
            Ok(vr) => vr,
            Err(err) => {
                if is_post_write_status(&err) {
                    return Err(err);
                }
                let reason = format_exit_reason(&err);
                return Err(record_unverified(created_id.as_deref(), &reason));
            }
        };

        if !v_res.ok {
            let mut rec = with_replaced_status(&base_pending, "PR_POST_WRITE_UNVERIFIED");
            rec.push(("reconciliation_required".to_string(), JsonValue::Bool(true)));
            rec.push((
                "created_id".to_string(),
                created_id
                    .as_deref()
                    .map_or(JsonValue::Null, JsonValue::str),
            ));
            rec.push(("detail".to_string(), JsonValue::str(&v_res.reason)));
            let _ = append_state_record(state_path, rec, false);
            let mut extra = vec![
                ("outcome".to_string(), JsonValue::str("mutated_unverified")),
                ("mutated".to_string(), JsonValue::Bool(true)),
                ("reconciliation_required".to_string(), JsonValue::Bool(true)),
                ("op_id".to_string(), JsonValue::str(&op_id)),
            ];
            if let Some(cid) = created_id.as_deref() {
                extra.push(("created_id".to_string(), JsonValue::str(cid)));
            }
            extra.extend(extra_ids.clone());
            return Err(pr_fail(
                "PR_POST_WRITE_UNVERIFIED",
                format!("Remote verification failed for {action} ({})", v_res.reason),
                EXIT_ERROR,
                extra,
            ));
        }

        if v_res.post_head != expected_head || v_res.post_state != "OPEN" {
            let mut rec = with_replaced_status(&base_pending, "PR_POST_WRITE_HEAD_MOVED");
            rec.push(("reconciliation_required".to_string(), JsonValue::Bool(true)));
            rec.push((
                "created_id".to_string(),
                created_id
                    .as_deref()
                    .map_or(JsonValue::Null, JsonValue::str),
            ));
            rec.push(("remote_head".to_string(), JsonValue::str(&v_res.post_head)));
            rec.push((
                "remote_state".to_string(),
                JsonValue::str(&v_res.post_state),
            ));
            let _ = append_state_record(state_path, rec, false);
            let mut extra = vec![
                ("outcome".to_string(), JsonValue::str("mutated_but_stale")),
                ("mutated".to_string(), JsonValue::Bool(true)),
                ("reconciliation_required".to_string(), JsonValue::Bool(true)),
                ("op_id".to_string(), JsonValue::str(&op_id)),
            ];
            if let Some(cid) = created_id.as_deref() {
                extra.push(("created_id".to_string(), JsonValue::str(cid)));
            }
            extra.extend(extra_ids);
            extra.push(("expected_head".to_string(), JsonValue::str(expected_head)));
            extra.push(("remote_head".to_string(), JsonValue::str(&v_res.post_head)));
            extra.push((
                "remote_state".to_string(),
                JsonValue::str(&v_res.post_state),
            ));
            return Err(pr_fail(
                "PR_POST_WRITE_HEAD_MOVED",
                format!(
                    "PR state/HEAD changed concurrently after {action} (state={}, head={expected_head} -> {})",
                    v_res.post_state, v_res.post_head
                ),
                EXIT_BLOCKED,
                extra,
            ));
        }

        let final_payload = on_success_payload(&prep_state, &header, created_id.as_deref(), &v_res);
        let final_status = final_payload
            .get("status")
            .and_then(JsonValue::as_str)
            .unwrap_or("OK");
        let mut fin_rec = with_replaced_status(&base_pending, final_status);
        fin_rec.push((
            "reconciliation_required".to_string(),
            JsonValue::Bool(false),
        ));
        fin_rec.push((
            "created_id".to_string(),
            created_id
                .as_deref()
                .map_or(JsonValue::Null, JsonValue::str),
        ));
        fin_rec.push(("head_sha".to_string(), JsonValue::str(&v_res.post_head)));
        let _ = append_state_record(state_path, fin_rec, false);
        Ok(pr_emit(final_payload, EXIT_OK))
    })
}

fn with_replaced_status(base: &[(String, JsonValue)], status: &str) -> Vec<(String, JsonValue)> {
    base.iter()
        .map(|(k, v)| {
            if k == "status" {
                (k.clone(), JsonValue::str(status))
            } else {
                (k.clone(), v.clone())
            }
        })
        .collect()
}

fn is_post_write_status(err: &PrExit) -> bool {
    matches!(
        err.payload.get("status").and_then(JsonValue::as_str),
        Some("PR_POST_WRITE_UNVERIFIED" | "PR_POST_WRITE_HEAD_MOVED")
    )
}

fn format_exit_reason(err: &PrExit) -> String {
    let st = err
        .payload
        .get("status")
        .and_then(JsonValue::as_str)
        .unwrap_or("");
    let msg = err
        .payload
        .get("error")
        .and_then(JsonValue::as_str)
        .unwrap_or("");
    format!("{st}: {msg}")
}

fn unique_op_hex8() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let seed = format!(
        "{}:{}:{}",
        std::process::id(),
        nanos,
        crate::fs::next_tmp_suffix()
    );
    sha256_utf8_hex(&seed)[..16].to_string()
}

fn unique_ordered_authors(comments: &[ThreadComment]) -> Vec<JsonValue> {
    let mut seen = BTreeSet::new();
    let mut out = Vec::new();
    for c in comments {
        if seen.insert(c.author.clone()) {
            out.push(JsonValue::str(frame_untrusted_text(&c.author)));
        }
    }
    out
}

fn handle_fetch(flags: &ParsedFlags) -> Result<PrExit, PrExit> {
    let repo = validate_repo_flag(flags.str_opt("repo"))?;
    let pr_number = validate_pr_flag(flags.str_opt("pr"))?;
    let max_pages = validate_max_pages_flag(flags.str_opt("max-pages"))?;
    let include_resolved = flags.bool_flag("include-resolved");
    let include_bodies = flags.bool_flag("include-bodies");
    let mut selected_ids = Vec::new();
    if let Some(raw_ids) = flags.str_opt("thread-id") {
        for part in raw_ids.split(',') {
            let trimmed = part.trim();
            if !trimmed.is_empty() {
                selected_ids.push(validate_id_flag(Some(trimmed), "--thread-id")?);
            }
        }
    }

    if !selected_ids.is_empty() {
        if selected_ids.len() > 50 {
            return Err(err_simple(
                "PR_INVALID_ARGS",
                "At most 50 --thread-id values allowed",
            ));
        }
        let header = fetch_pr_header(&repo.owner, &repo.name, pr_number)?;
        let mut review_threads = Vec::with_capacity(selected_ids.len());
        for tid in &selected_ids {
            let Some(t) = fetch_single_review_thread(&repo.full, pr_number, tid, max_pages, true)?
            else {
                return Err(err_simple(
                    "PR_TARGET_MISMATCH",
                    format!(
                        "Review thread {tid} does not belong to {}#{pr_number}",
                        repo.full
                    ),
                ));
            };
            let authors = unique_ordered_authors(&t.comments);
            let comments: Vec<JsonValue> = t
                .comments
                .iter()
                .map(|c| {
                    JsonValue::obj(vec![
                        ("id".to_string(), JsonValue::str(&c.id)),
                        (
                            "author".to_string(),
                            JsonValue::str(frame_untrusted_text(&c.author)),
                        ),
                        (
                            "body".to_string(),
                            JsonValue::str(frame_untrusted_text(c.body.as_deref().unwrap_or(""))),
                        ),
                    ])
                })
                .collect();
            let line_val = t.line.map_or(JsonValue::Null, JsonValue::num_i64);
            review_threads.push(JsonValue::obj(vec![
                ("id".to_string(), JsonValue::str(&t.id)),
                ("target_kind".to_string(), JsonValue::str("review_thread")),
                ("is_resolved".to_string(), JsonValue::Bool(t.is_resolved)),
                ("is_outdated".to_string(), JsonValue::Bool(t.is_outdated)),
                (
                    "path".to_string(),
                    JsonValue::str(frame_untrusted_text(&t.path)),
                ),
                ("line".to_string(), line_val),
                (
                    "comment_count".to_string(),
                    JsonValue::num_u64(t.comments.len() as u64),
                ),
                ("authors".to_string(), JsonValue::Array(authors)),
                ("comments".to_string(), JsonValue::Array(comments)),
            ]));
        }
        let payload = JsonValue::obj(vec![
            ("status".to_string(), JsonValue::str("PR_FETCH_OK")),
            (
                "retrieval_mode".to_string(),
                JsonValue::str("targeted_threads"),
            ),
            ("repo".to_string(), JsonValue::str(&repo.full)),
            ("pr".to_string(), JsonValue::num_u64(pr_number)),
            ("viewer".to_string(), JsonValue::str(&header.viewer)),
            ("untrusted_data_framed".to_string(), JsonValue::Bool(true)),
            (
                "pull_request".to_string(),
                JsonValue::obj(vec![
                    ("number".to_string(), JsonValue::num_u64(pr_number)),
                    ("state".to_string(), JsonValue::str(&header.state)),
                    ("head_sha".to_string(), JsonValue::str(&header.head_sha)),
                ]),
            ),
            (
                "counts".to_string(),
                JsonValue::obj(vec![
                    (
                        "returned_review_threads".to_string(),
                        JsonValue::num_u64(review_threads.len() as u64),
                    ),
                    ("general_comments".to_string(), JsonValue::num_u64(0)),
                ]),
            ),
            (
                "review_threads".to_string(),
                JsonValue::Array(review_threads),
            ),
            ("general_comments".to_string(), JsonValue::Array(Vec::new())),
        ]);
        return Ok(pr_emit(payload, EXIT_OK));
    }

    let (viewer, pr_meta, threads) = fetch_all_review_threads(
        &repo.owner,
        &repo.name,
        pr_number,
        max_pages,
        include_bodies,
    )?;
    let raw_gen = fetch_rest_paginated(
        &format!("repos/{}/issues/{pr_number}/comments", repo.full),
        max_pages,
    )?;
    let visible: Vec<&ReviewThread> = if include_resolved {
        threads.iter().collect()
    } else {
        threads.iter().filter(|t| !t.is_resolved).collect()
    };
    let review_threads: Vec<JsonValue> = visible
        .iter()
        .map(|t| {
            let mut entries = vec![
                ("id".to_string(), JsonValue::str(&t.id)),
                ("target_kind".to_string(), JsonValue::str("review_thread")),
                ("is_resolved".to_string(), JsonValue::Bool(t.is_resolved)),
                ("is_outdated".to_string(), JsonValue::Bool(t.is_outdated)),
                (
                    "path".to_string(),
                    JsonValue::str(frame_untrusted_text(&t.path)),
                ),
                (
                    "line".to_string(),
                    t.line.map_or(JsonValue::Null, JsonValue::num_i64),
                ),
                (
                    "comment_count".to_string(),
                    JsonValue::num_i64(t.total_count),
                ),
                (
                    "authors".to_string(),
                    JsonValue::Array(unique_ordered_authors(&t.comments)),
                ),
            ];
            if include_bodies {
                let comments: Vec<JsonValue> = t
                    .comments
                    .iter()
                    .map(|c| {
                        JsonValue::obj(vec![
                            ("id".to_string(), JsonValue::str(&c.id)),
                            (
                                "author".to_string(),
                                JsonValue::str(frame_untrusted_text(&c.author)),
                            ),
                            (
                                "body".to_string(),
                                JsonValue::str(frame_untrusted_text(
                                    c.body.as_deref().unwrap_or(""),
                                )),
                            ),
                        ])
                    })
                    .collect();
                entries.push(("comments".to_string(), JsonValue::Array(comments)));
            } else if t.has_more_nested_comments {
                entries.push(("nested_comments_omitted".to_string(), JsonValue::Bool(true)));
            }
            JsonValue::Object(entries)
        })
        .collect();

    let general_comments: Vec<JsonValue> = raw_gen
        .iter()
        .map(|c| {
            let cid = c
                .get("id")
                .and_then(JsonValue::to_text_string)
                .unwrap_or_default();
            let html_url = c
                .get("html_url")
                .and_then(JsonValue::as_str)
                .filter(|s| !s.is_empty())
                .map_or(JsonValue::Null, JsonValue::str);
            let author = c
                .get("user")
                .and_then(|u| u.get("login"))
                .and_then(JsonValue::as_str)
                .filter(|s| !s.is_empty())
                .unwrap_or("unknown");
            let mut entries = vec![
                ("id".to_string(), JsonValue::str(cid)),
                ("target_kind".to_string(), JsonValue::str("general_comment")),
                ("resolvable".to_string(), JsonValue::Bool(false)),
                ("html_url".to_string(), html_url),
                (
                    "author".to_string(),
                    JsonValue::str(frame_untrusted_text(author)),
                ),
            ];
            if include_bodies {
                let body = c.get("body").and_then(JsonValue::as_str).unwrap_or("");
                entries.push((
                    "body".to_string(),
                    JsonValue::str(frame_untrusted_text(body)),
                ));
            }
            JsonValue::Object(entries)
        })
        .collect();

    let mut pr_entries = vec![
        ("number".to_string(), JsonValue::num_u64(pr_meta.number)),
        ("state".to_string(), JsonValue::str(&pr_meta.state)),
        ("head_sha".to_string(), JsonValue::str(&pr_meta.head_sha)),
        (
            "title".to_string(),
            JsonValue::str(frame_untrusted_text(&pr_meta.title)),
        ),
        (
            "base_ref".to_string(),
            JsonValue::str(frame_untrusted_text(&pr_meta.base_ref_name)),
        ),
        (
            "head_ref".to_string(),
            JsonValue::str(frame_untrusted_text(&pr_meta.head_ref_name)),
        ),
    ];
    if include_bodies {
        pr_entries.push((
            "body".to_string(),
            JsonValue::str(frame_untrusted_text(pr_meta.body.as_deref().unwrap_or(""))),
        ));
    }

    let retrieval_mode = if include_bodies {
        "full_with_bodies"
    } else {
        "metadata_first"
    };
    let payload = JsonValue::obj(vec![
        ("status".to_string(), JsonValue::str("PR_FETCH_OK")),
        ("retrieval_mode".to_string(), JsonValue::str(retrieval_mode)),
        ("repo".to_string(), JsonValue::str(&repo.full)),
        ("pr".to_string(), JsonValue::num_u64(pr_number)),
        ("viewer".to_string(), JsonValue::str(&viewer)),
        ("untrusted_data_framed".to_string(), JsonValue::Bool(true)),
        (
            "include_resolved".to_string(),
            JsonValue::Bool(include_resolved),
        ),
        (
            "include_bodies".to_string(),
            JsonValue::Bool(include_bodies),
        ),
        ("pull_request".to_string(), JsonValue::Object(pr_entries)),
        (
            "counts".to_string(),
            JsonValue::obj(vec![
                (
                    "total_review_threads".to_string(),
                    JsonValue::num_u64(threads.len() as u64),
                ),
                (
                    "returned_review_threads".to_string(),
                    JsonValue::num_u64(review_threads.len() as u64),
                ),
                (
                    "general_comments".to_string(),
                    JsonValue::num_u64(general_comments.len() as u64),
                ),
            ]),
        ),
        (
            "review_threads".to_string(),
            JsonValue::Array(review_threads),
        ),
        (
            "general_comments".to_string(),
            JsonValue::Array(general_comments),
        ),
    ]);
    Ok(pr_emit(payload, EXIT_OK))
}

fn parse_expected_inline_from_record(rec: &JsonValue) -> Vec<InlineCommentSpec> {
    let Some(arr) = rec.get("expected_inline").and_then(JsonValue::as_array) else {
        return Vec::new();
    };
    arr.iter()
        .filter_map(|item| {
            let path = item.get("path").and_then(JsonValue::as_str)?.to_string();
            let line = item.get("line").and_then(JsonValue::as_i64)?;
            let side = item
                .get("side")
                .and_then(JsonValue::as_str)
                .unwrap_or("RIGHT")
                .to_string();
            let body = item
                .get("body")
                .and_then(JsonValue::as_str)
                .unwrap_or("")
                .to_string();
            Some(InlineCommentSpec {
                path,
                line,
                side,
                body,
            })
        })
        .collect()
}

fn handle_reconcile(flags: &ParsedFlags) -> Result<PrExit, PrExit> {
    let repo = validate_repo_flag(flags.str_opt("repo"))?;
    let pr_number = validate_pr_flag(flags.str_opt("pr"))?;
    let max_pages = validate_max_pages_flag(flags.str_opt("max-pages"))?;
    let git_ctx = resolve_git_context(flags.str_opt("repo-root"))?;
    assert_mutation_owner_allowed(&git_ctx, "reconcile", flags.str_opt("repo-root"))?;
    let state_path = resolve_canonical_state_path(&git_ctx.git_common_dir, &repo.full, pr_number)?;

    with_state_lock(&state_path, "reconcile", || {
        let records = read_state_records(&state_path)?;
        let pending = get_unresolved_pending_records(&records, &repo.full, pr_number);
        if pending.is_empty() {
            return Ok(pr_emit(
                JsonValue::obj(vec![
                    ("status".to_string(), JsonValue::str("PR_RECONCILE_OK")),
                    ("repo".to_string(), JsonValue::str(&repo.full)),
                    ("pr".to_string(), JsonValue::num_u64(pr_number)),
                    ("reconciled_count".to_string(), JsonValue::num_u64(0)),
                    ("outcomes".to_string(), JsonValue::Array(Vec::new())),
                ]),
                EXIT_OK,
            ));
        }

        let header = fetch_pr_header(&repo.owner, &repo.name, pr_number)?;
        let mut outcomes = Vec::with_capacity(pending.len());
        let mut has_uncertain = false;

        let classify_found =
            |v: &VerifyRemoteOutcome, reviewed_sha: &str, label: &str| -> (String, String) {
                if !v.ok {
                    return ("UNCERTAIN".to_string(), v.reason.clone());
                }
                if v.post_head == reviewed_sha && v.post_state == "OPEN" {
                    return ("CONFIRMED_SUCCESS".to_string(), format!("verified_{label}"));
                }
                (
                    "STALE_MUTATION".to_string(),
                    format!(
                        "{label}_on_moved_or_nonopen_pr({},{})",
                        v.post_state, v.post_head
                    ),
                )
            };

        for rec in &pending {
            let op_id = rec
                .get("op_id")
                .and_then(JsonValue::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .unwrap_or("__missing_op_unknown")
                .to_string();
            let action = rec
                .get("action")
                .and_then(JsonValue::as_str)
                .unwrap_or("")
                .to_string();
            let rec_status = rec.get("status").and_then(JsonValue::as_str).unwrap_or("");
            let reviewed_sha = rec
                .get("reviewed_sha")
                .and_then(JsonValue::as_str)
                .unwrap_or("")
                .to_string();
            let actor = rec
                .get("actor")
                .and_then(JsonValue::as_str)
                .filter(|s| !s.is_empty())
                .unwrap_or(&header.viewer)
                .to_string();
            let key = rec.get("key").and_then(JsonValue::as_str).unwrap_or("");
            let op_hash = rec.get("op_hash").and_then(JsonValue::as_str).unwrap_or("");
            let marker = if !key.is_empty() && !op_hash.is_empty() {
                format!("<!-- b3-pr-key:{key};op={op_hash} -->")
            } else {
                String::new()
            };
            let target_id = rec
                .get("target_id")
                .and_then(JsonValue::to_text_string)
                .unwrap_or_default();
            let target_kind = rec
                .get("target_kind")
                .and_then(JsonValue::as_str)
                .unwrap_or("");
            let transport = rec
                .get("transport")
                .and_then(JsonValue::as_str)
                .unwrap_or("");
            let mut resolved_id = rec.get("created_id").and_then(JsonValue::to_text_string);
            let mut outcome = "UNCERTAIN".to_string();
            let mut detail = "unverifiable_record".to_string();

            if action == "resolve" && !target_id.is_empty() {
                let spec = VerifyRemoteSpec {
                    kind: "resolve_thread",
                    repo: &repo.full,
                    pr: pr_number,
                    viewer: &actor,
                    created_id: "",
                    thread_id: &target_id,
                    expected_head: "",
                    expected_body: None,
                    expected_body_sha256: "",
                    marker: "",
                    event: "",
                    expected_inline: &[],
                };
                let v = verify_remote_object(&spec, max_pages)?;
                if !v.found {
                    outcome = "UNCERTAIN".to_string();
                    detail = "thread_not_found".to_string();
                } else if v.ok {
                    (outcome, detail) = classify_found(&v, &reviewed_sha, "resolve");
                } else if !v.is_resolved && rec_status == "PENDING" {
                    outcome = "CONFIRMED_ABSENCE".to_string();
                    detail = "thread_still_unresolved".to_string();
                } else {
                    outcome = "UNCERTAIN".to_string();
                    detail = v.reason;
                }
            } else if (action == "reply" && target_kind == "review_thread" && !target_id.is_empty())
                || (action == "reply" && target_kind == "general_comment")
                || (action == "comment"
                    && (transport == "issue_comment" || transport == "pull_review"))
            {
                let kind = if target_kind == "review_thread" {
                    "review_thread_reply"
                } else if transport == "pull_review" {
                    "pull_review"
                } else {
                    "issue_comment"
                };
                if resolved_id.is_none() && !marker.is_empty() {
                    if kind == "review_thread_reply" {
                        if let Some(th) = fetch_single_review_thread(
                            &repo.full, pr_number, &target_id, max_pages, true,
                        )? {
                            if let Some(hit) = th.comments.iter().find(|c| {
                                c.author.eq_ignore_ascii_case(&actor)
                                    && c.body.as_deref().unwrap_or("").contains(&marker)
                            }) {
                                resolved_id = Some(hit.id.clone());
                            }
                        }
                    } else if kind == "issue_comment" {
                        let comments = fetch_rest_paginated(
                            &format!("repos/{}/issues/{pr_number}/comments", repo.full),
                            max_pages,
                        )?;
                        if let Some(hit) = comments.iter().find(|c| {
                            c.get("user")
                                .and_then(|u| u.get("login"))
                                .and_then(JsonValue::as_str)
                                .unwrap_or("")
                                .eq_ignore_ascii_case(&actor)
                                && c.get("body")
                                    .and_then(JsonValue::as_str)
                                    .unwrap_or("")
                                    .contains(&marker)
                        }) {
                            resolved_id = hit.get("id").and_then(JsonValue::to_text_string);
                        }
                    } else {
                        let reviews = fetch_rest_paginated(
                            &format!("repos/{}/pulls/{pr_number}/reviews", repo.full),
                            max_pages,
                        )?;
                        if let Some(hit) = reviews.iter().find(|r| {
                            r.get("user")
                                .and_then(|u| u.get("login"))
                                .and_then(JsonValue::as_str)
                                .unwrap_or("")
                                .eq_ignore_ascii_case(&actor)
                                && r.get("body")
                                    .and_then(JsonValue::as_str)
                                    .unwrap_or("")
                                    .contains(&marker)
                        }) {
                            resolved_id = hit.get("id").and_then(JsonValue::to_text_string);
                        }
                    }
                }

                if let Some(cid) = resolved_id.as_deref() {
                    let body_sha = rec
                        .get("body_sha256")
                        .and_then(JsonValue::as_str)
                        .unwrap_or("");
                    let ev = rec.get("event").and_then(JsonValue::as_str).unwrap_or("");
                    let exp_inline = parse_expected_inline_from_record(rec);
                    let spec = VerifyRemoteSpec {
                        kind,
                        repo: &repo.full,
                        pr: pr_number,
                        viewer: &actor,
                        created_id: cid,
                        thread_id: &target_id,
                        expected_head: &reviewed_sha,
                        expected_body: None,
                        expected_body_sha256: body_sha,
                        marker: &marker,
                        event: ev,
                        expected_inline: &exp_inline,
                    };
                    let v = verify_remote_object(&spec, max_pages)?;
                    if !v.found {
                        outcome = "UNCERTAIN".to_string();
                        detail = "recorded_id_missing_remotely".to_string();
                    } else {
                        (outcome, detail) = classify_found(&v, &reviewed_sha, kind);
                    }
                } else if rec_status == "PENDING" && !marker.is_empty() {
                    outcome = "CONFIRMED_ABSENCE".to_string();
                    detail = format!("no_matching_{kind}_found");
                } else {
                    outcome = "UNCERTAIN".to_string();
                    detail = "missing_identity_for_reconciliation".to_string();
                }
            }

            let created_id_json = resolved_id
                .as_deref()
                .map_or(JsonValue::Null, JsonValue::str);
            outcomes.push(JsonValue::obj(vec![
                ("op_id".to_string(), JsonValue::str(&op_id)),
                ("action".to_string(), JsonValue::str(&action)),
                ("outcome".to_string(), JsonValue::str(&outcome)),
                ("detail".to_string(), JsonValue::str(&detail)),
                ("created_id".to_string(), created_id_json.clone()),
                ("reviewed_sha".to_string(), JsonValue::str(&reviewed_sha)),
                ("remote_head".to_string(), JsonValue::str(&header.head_sha)),
                ("remote_state".to_string(), JsonValue::str(&header.state)),
            ]));

            if outcome == "CONFIRMED_SUCCESS" {
                append_state_record(
                    &state_path,
                    vec![
                        ("op_id".to_string(), JsonValue::str(&op_id)),
                        ("action".to_string(), JsonValue::str("reconcile")),
                        ("status".to_string(), JsonValue::str("RECONCILED_CONFIRMED")),
                        ("repo".to_string(), JsonValue::str(&repo.full)),
                        ("pr".to_string(), JsonValue::num_u64(pr_number)),
                        ("created_id".to_string(), created_id_json),
                        ("remote_head".to_string(), JsonValue::str(&header.head_sha)),
                    ],
                    true,
                )?;
            } else if outcome == "CONFIRMED_ABSENCE" {
                append_state_record(
                    &state_path,
                    vec![
                        ("op_id".to_string(), JsonValue::str(&op_id)),
                        ("action".to_string(), JsonValue::str("reconcile")),
                        ("status".to_string(), JsonValue::str("RECONCILED_ABSENT")),
                        ("repo".to_string(), JsonValue::str(&repo.full)),
                        ("pr".to_string(), JsonValue::num_u64(pr_number)),
                        ("remote_head".to_string(), JsonValue::str(&header.head_sha)),
                    ],
                    true,
                )?;
            } else if outcome == "STALE_MUTATION" {
                append_state_record(
                    &state_path,
                    vec![
                        ("op_id".to_string(), JsonValue::str(&op_id)),
                        ("action".to_string(), JsonValue::str("reconcile")),
                        ("status".to_string(), JsonValue::str("RECONCILED_STALE")),
                        ("repo".to_string(), JsonValue::str(&repo.full)),
                        ("pr".to_string(), JsonValue::num_u64(pr_number)),
                        ("created_id".to_string(), created_id_json),
                        ("reviewed_sha".to_string(), JsonValue::str(&reviewed_sha)),
                        ("remote_head".to_string(), JsonValue::str(&header.head_sha)),
                    ],
                    true,
                )?;
            } else {
                has_uncertain = true;
            }
        }

        if has_uncertain {
            return Err(pr_fail(
                "PR_RECONCILIATION_UNCERTAIN",
                "One or more pending operations could not be safely reconciled; dependent writes remain blocked",
                EXIT_BLOCKED,
                vec![
                    ("repo".to_string(), JsonValue::str(&repo.full)),
                    ("pr".to_string(), JsonValue::num_u64(pr_number)),
                    ("remote_head".to_string(), JsonValue::str(&header.head_sha)),
                    ("outcomes".to_string(), JsonValue::Array(outcomes)),
                ],
            ));
        }

        Ok(pr_emit(
            JsonValue::obj(vec![
                ("status".to_string(), JsonValue::str("PR_RECONCILE_OK")),
                ("repo".to_string(), JsonValue::str(&repo.full)),
                ("pr".to_string(), JsonValue::num_u64(pr_number)),
                ("remote_head".to_string(), JsonValue::str(&header.head_sha)),
                (
                    "reconciled_count".to_string(),
                    JsonValue::num_u64(outcomes.len() as u64),
                ),
                ("outcomes".to_string(), JsonValue::Array(outcomes)),
            ]),
            EXIT_OK,
        ))
    })
}

fn format_general_reply_with_ref(
    raw_body: &str,
    target_id: &str,
    html_url: Option<&str>,
) -> String {
    let clean = normalize_text(raw_body);
    let url_present = html_url.is_some_and(|u| !u.is_empty() && clean.contains(u));
    if url_present || clean.contains(&format!("#issuecomment-{target_id}")) {
        return clean;
    }
    let ref_line = match html_url {
        Some(u)
            if u.get(..7)
                .is_some_and(|p| p.eq_ignore_ascii_case("http://"))
                || u.get(..8)
                    .is_some_and(|p| p.eq_ignore_ascii_case("https://")) =>
        {
            format!("> Replying to [comment #{target_id}]({u})")
        }
        _ => format!("> Replying to comment #{target_id} (#issuecomment-{target_id})"),
    };
    format!("{ref_line}\n\n{clean}")
}

struct ReplyPrep {
    base_body: String,
    final_body: String,
    identity: OpIdentity,
    target_url: Option<String>,
}

fn handle_reply(flags: &ParsedFlags) -> Result<PrExit, PrExit> {
    let repo = validate_repo_flag(flags.str_opt("repo"))?;
    let pr_number = validate_pr_flag(flags.str_opt("pr"))?;
    let expected_head = validate_sha_flag(flags.str_opt("expected-head"), "--expected-head")?;
    let target_kind = flags.str_opt("target-kind").unwrap_or("");
    if !matches!(target_kind, "review_thread" | "general_comment") {
        return Err(err_simple(
            "PR_INVALID_ARGS",
            "Invalid --target-kind (expected review_thread|general_comment)",
        ));
    }
    let target_id = validate_id_flag(flags.str_opt("target-id"), "--target-id")?;
    let body_file = flags.str_opt("body-file").unwrap_or("");
    let raw_body = read_safe_input_file(body_file, "--body-file", MAX_FILE_BYTES)?;
    if raw_body.trim().is_empty() {
        return Err(err_simple("PR_INVALID_ARGS", "--body-file is empty"));
    }
    let explicit_key = validate_key_flag(flags.str_opt("idempotency-key"))?;
    let max_pages = validate_max_pages_flag(flags.str_opt("max-pages"))?;
    let is_draft = flags.bool_flag("draft");
    let auth_write = flags.bool_flag("authorize-write");
    if is_draft && auth_write {
        return Err(err_simple(
            "PR_INVALID_ARGS",
            "--draft cannot be combined with --authorize-write",
        ));
    }

    if is_draft {
        let preview_base = if target_kind == "general_comment" {
            format_general_reply_with_ref(&raw_body, &target_id, None)
        } else {
            normalize_text(&raw_body)
        };
        let id_obj = compute_operation_identity(
            &repo.full,
            pr_number,
            "draft",
            "reply",
            target_kind,
            &target_id,
            &expected_head,
            "",
            "",
            &preview_base,
            &explicit_key,
        );
        let preview = append_marker(&preview_base, &id_obj.marker);
        if preview.chars().count() > MAX_BODY_CHARS {
            return Err(err_simple(
                "PR_FILE_GUARD",
                format!("Reply body exceeds {MAX_BODY_CHARS} chars"),
            ));
        }
        return Ok(pr_emit(
            JsonValue::obj(vec![
                ("status".to_string(), JsonValue::str("PR_DRAFT_OK")),
                ("action".to_string(), JsonValue::str("reply")),
                ("mutated".to_string(), JsonValue::Bool(false)),
                ("repo".to_string(), JsonValue::str(&repo.full)),
                ("pr".to_string(), JsonValue::num_u64(pr_number)),
                ("expected_head".to_string(), JsonValue::str(&expected_head)),
                ("target_kind".to_string(), JsonValue::str(target_kind)),
                ("target_id".to_string(), JsonValue::str(&target_id)),
                ("idempotency_key".to_string(), JsonValue::str(&id_obj.key)),
                (
                    "operation_hash".to_string(),
                    JsonValue::str(&id_obj.op_hash),
                ),
                ("body_preview".to_string(), JsonValue::str(preview)),
            ]),
            EXIT_OK,
        ));
    }

    if !auth_write {
        return Err(err_blocked_before_write(
            "PR_AUTH_REQUIRED",
            "Explicit --authorize-write is required to post a PR reply (or use --draft)",
            Vec::new(),
        ));
    }

    let git_ctx = resolve_git_context(flags.str_opt("repo-root"))?;
    assert_mutation_owner_allowed(&git_ctx, "reply", flags.str_opt("repo-root"))?;
    let state_path = resolve_canonical_state_path(&git_ctx.git_common_dir, &repo.full, pr_number)?;

    execute_guarded_mutation(
        &state_path,
        &repo,
        pr_number,
        &expected_head,
        "reply",
        max_pages,
        |header| {
            let mut target_url: Option<String> = None;
            let mut base_body = normalize_text(&raw_body);
            let scan_items: Vec<IdemCandidate> = if target_kind == "review_thread" {
                let Some(thread) =
                    fetch_single_review_thread(&repo.full, pr_number, &target_id, max_pages, true)?
                else {
                    return Err(err_simple(
                        "PR_TARGET_MISMATCH",
                        format!(
                            "Review thread {target_id} does not belong to {}#{pr_number}",
                            repo.full
                        ),
                    ));
                };
                thread
                    .comments
                    .into_iter()
                    .map(|c| IdemCandidate {
                        id: c.id,
                        kind: "review_thread_reply".to_string(),
                        author: c.author,
                        body: c.body.unwrap_or_default(),
                    })
                    .collect()
            } else {
                let t_res = gh_rest_get(
                    &format!("repos/{}/issues/comments/{target_id}", repo.full),
                    true,
                )?;
                let GhResponse::Data(Some(t_data)) = t_res else {
                    return Err(err_simple(
                        "PR_TARGET_MISMATCH",
                        format!(
                            "General PR comment {target_id} does not belong to {}#{pr_number}",
                            repo.full
                        ),
                    ));
                };
                let tid_str = t_data
                    .get("id")
                    .and_then(JsonValue::to_text_string)
                    .unwrap_or_default();
                let issue_url = t_data
                    .get("issue_url")
                    .and_then(JsonValue::as_str)
                    .unwrap_or("");
                if tid_str != target_id || !issue_url.ends_with(&format!("/issues/{pr_number}")) {
                    return Err(err_simple(
                        "PR_TARGET_MISMATCH",
                        format!(
                            "General PR comment {target_id} does not belong to {}#{pr_number}",
                            repo.full
                        ),
                    ));
                }
                target_url = t_data
                    .get("html_url")
                    .and_then(JsonValue::as_str)
                    .filter(|s| !s.is_empty())
                    .map(str::to_string);
                base_body =
                    format_general_reply_with_ref(&raw_body, &target_id, target_url.as_deref());
                let raw_list = fetch_rest_paginated(
                    &format!("repos/{}/issues/{pr_number}/comments", repo.full),
                    max_pages,
                )?;
                raw_list
                    .iter()
                    .map(|c| IdemCandidate {
                        id: c
                            .get("id")
                            .and_then(JsonValue::to_text_string)
                            .unwrap_or_default(),
                        kind: "issue_comment".to_string(),
                        author: c
                            .get("user")
                            .and_then(|u| u.get("login"))
                            .and_then(JsonValue::as_str)
                            .unwrap_or("")
                            .to_string(),
                        body: c
                            .get("body")
                            .and_then(JsonValue::as_str)
                            .unwrap_or("")
                            .to_string(),
                    })
                    .collect()
            };

            let identity = compute_operation_identity(
                &repo.full,
                pr_number,
                &header.viewer,
                "reply",
                target_kind,
                &target_id,
                &expected_head,
                "",
                "",
                &base_body,
                &explicit_key,
            );
            let final_body = append_marker(&base_body, &identity.marker);
            if final_body.chars().count() > MAX_BODY_CHARS {
                return Err(err_simple(
                    "PR_FILE_GUARD",
                    format!("Reply body exceeds {MAX_BODY_CHARS} chars"),
                ));
            }

            let v_kind = if target_kind == "review_thread" {
                "review_thread_reply"
            } else {
                "issue_comment"
            };
            let v_tid = if target_kind == "review_thread" {
                target_id.as_str()
            } else {
                ""
            };
            let idem = check_idempotency_with_revalidation(
                &scan_items,
                &header.viewer,
                &identity,
                |cand, exp_marker| {
                    let spec = VerifyRemoteSpec {
                        kind: v_kind,
                        repo: &repo.full,
                        pr: pr_number,
                        viewer: &header.viewer,
                        created_id: &cand.id,
                        thread_id: v_tid,
                        expected_head: "",
                        expected_body: Some(&base_body),
                        expected_body_sha256: "",
                        marker: exp_marker,
                        event: "",
                        expected_inline: &[],
                    };
                    verify_remote_object(&spec, max_pages)
                },
            )?;

            match idem {
                IdemStatus::Collision { existing_id } => Err(err_blocked_before_write(
                    "PR_KEY_COLLISION",
                    format!(
                        "Idempotency key {} already used for a different operation ({existing_id})",
                        identity.key
                    ),
                    vec![
                        ("existing_comment_id".to_string(), JsonValue::str(existing_id)),
                        ("key".to_string(), JsonValue::str(&identity.key)),
                    ],
                )),
                IdemStatus::RemoteMismatch {
                    existing_id,
                    reason,
                } => Err(err_blocked_before_write(
                    "PR_REMOTE_STATE_MISMATCH",
                    format!(
                        "Existing remote comment {existing_id} with marker {} does not match expected content/target ({reason})",
                        identity.key
                    ),
                    vec![
                        ("existing_comment_id".to_string(), JsonValue::str(existing_id)),
                        ("key".to_string(), JsonValue::str(&identity.key)),
                    ],
                )),
                IdemStatus::Match { existing_id } => Ok(PrepareResult::EarlyEmit {
                    payload: JsonValue::obj(vec![
                        ("status".to_string(), JsonValue::str("PR_IDEMPOTENT_SKIP")),
                        ("action".to_string(), JsonValue::str("reply")),
                        ("mutated".to_string(), JsonValue::Bool(false)),
                        ("target_kind".to_string(), JsonValue::str(target_kind)),
                        ("target_id".to_string(), JsonValue::str(&target_id)),
                        ("key".to_string(), JsonValue::str(&identity.key)),
                        (
                            "operation_hash".to_string(),
                            JsonValue::str(&identity.op_hash),
                        ),
                        (
                            "existing_comment_id".to_string(),
                            JsonValue::str(&existing_id),
                        ),
                    ]),
                    audit_record: Some(vec![
                        (
                            "op_id".to_string(),
                            JsonValue::str(format!("skip-{}", identity.op_hash)),
                        ),
                        ("action".to_string(), JsonValue::str("reply")),
                        ("status".to_string(), JsonValue::str("PR_IDEMPOTENT_SKIP")),
                        ("repo".to_string(), JsonValue::str(&repo.full)),
                        ("pr".to_string(), JsonValue::num_u64(pr_number)),
                        ("target_kind".to_string(), JsonValue::str(target_kind)),
                        ("target_id".to_string(), JsonValue::str(&target_id)),
                        ("key".to_string(), JsonValue::str(&identity.key)),
                        ("op_hash".to_string(), JsonValue::str(&identity.op_hash)),
                        ("comment_id".to_string(), JsonValue::str(existing_id)),
                    ]),
                }),
                IdemStatus::None => {
                    let body_sha = sha256_utf8_hex(&strip_markers(&base_body));
                    Ok(PrepareResult::Proceed {
                        pending_meta: vec![
                            ("target_kind".to_string(), JsonValue::str(target_kind)),
                            ("target_id".to_string(), JsonValue::str(&target_id)),
                            ("key".to_string(), JsonValue::str(&identity.key)),
                            ("op_hash".to_string(), JsonValue::str(&identity.op_hash)),
                            ("body_sha256".to_string(), JsonValue::str(body_sha)),
                        ],
                        extra_ids: vec![("target_id".to_string(), JsonValue::str(&target_id))],
                        state: ReplyPrep {
                            base_body,
                            final_body,
                            identity,
                            target_url,
                        },
                    })
                }
            }
        },
        || Ok(()),
        |prep, _header| {
            if target_kind == "review_thread" {
                let m = "mutation($threadId: ID!, $body: String!) { addPullRequestReviewThreadReply(input: { pullRequestReviewThreadId: $threadId, body: $body }) { comment { id url } } }";
                let vars = JsonValue::obj(vec![
                    ("threadId".to_string(), JsonValue::str(&target_id)),
                    ("body".to_string(), JsonValue::str(&prep.final_body)),
                ]);
                let res = gh_graphql(m, vars)?;
                let cid = res
                    .get("addPullRequestReviewThreadReply")
                    .and_then(|a| a.get("comment"))
                    .and_then(|c| c.get("id"))
                    .and_then(JsonValue::to_text_string);
                Ok(MutationResult {
                    created_id: cid,
                    require_id: true,
                })
            } else {
                let body =
                    JsonValue::obj(vec![("body".to_string(), JsonValue::str(&prep.final_body))]);
                let res = gh_rest_post(
                    &format!("repos/{}/issues/{pr_number}/comments", repo.full),
                    &body,
                )?;
                let cid = res
                    .as_ref()
                    .and_then(|v| v.get("id"))
                    .and_then(JsonValue::to_text_string);
                Ok(MutationResult {
                    created_id: cid,
                    require_id: true,
                })
            }
        },
        |prep, header, created_id, pages| {
            let spec = VerifyRemoteSpec {
                kind: if target_kind == "review_thread" {
                    "review_thread_reply"
                } else {
                    "issue_comment"
                },
                repo: &repo.full,
                pr: pr_number,
                viewer: &header.viewer,
                created_id,
                thread_id: if target_kind == "review_thread" {
                    target_id.as_str()
                } else {
                    ""
                },
                expected_head: "",
                expected_body: Some(&prep.base_body),
                expected_body_sha256: "",
                marker: &prep.identity.marker,
                event: "",
                expected_inline: &[],
            };
            verify_remote_object(&spec, pages)
        },
        |prep, _header, created_id, v_res| {
            let mut entries = vec![
                ("status".to_string(), JsonValue::str("PR_REPLY_OK")),
                ("action".to_string(), JsonValue::str("reply")),
                ("mutated".to_string(), JsonValue::Bool(true)),
                ("repo".to_string(), JsonValue::str(&repo.full)),
                ("pr".to_string(), JsonValue::num_u64(pr_number)),
                ("target_kind".to_string(), JsonValue::str(target_kind)),
                ("target_id".to_string(), JsonValue::str(&target_id)),
            ];
            if let Some(u) = prep.target_url.as_deref() {
                entries.push(("referenced_url".to_string(), JsonValue::str(u)));
            }
            entries.push((
                "comment_id".to_string(),
                JsonValue::str(created_id.unwrap_or("")),
            ));
            entries.push((
                "idempotency_key".to_string(),
                JsonValue::str(&prep.identity.key),
            ));
            entries.push((
                "operation_hash".to_string(),
                JsonValue::str(&prep.identity.op_hash),
            ));
            entries.push(("verified_remote".to_string(), JsonValue::Bool(true)));
            entries.push((
                "verified_head".to_string(),
                JsonValue::str(&v_res.post_head),
            ));
            JsonValue::Object(entries)
        },
    )
}

fn handle_resolve(flags: &ParsedFlags) -> Result<PrExit, PrExit> {
    let repo = validate_repo_flag(flags.str_opt("repo"))?;
    let pr_number = validate_pr_flag(flags.str_opt("pr"))?;
    let expected_head = validate_sha_flag(flags.str_opt("expected-head"), "--expected-head")?;
    let thread_id = validate_id_flag(flags.str_opt("thread-id"), "--thread-id")?;
    let fix_commit = validate_sha_flag(flags.str_opt("fix-commit"), "--fix-commit")?;
    let max_pages = validate_max_pages_flag(flags.str_opt("max-pages"))?;
    let is_draft = flags.bool_flag("draft");
    let auth_resolve = flags.bool_flag("authorize-resolve");

    if is_draft && auth_resolve {
        return Err(err_simple(
            "PR_INVALID_ARGS",
            "--draft cannot be combined with --authorize-resolve",
        ));
    }
    if thread_id.bytes().all(|b| b.is_ascii_digit()) || thread_id.starts_with("IC_") {
        return Err(err_simple(
            "PR_NOT_RESOLVABLE",
            format!("General PR comments ({thread_id}) cannot be resolved as review threads"),
        ));
    }

    let git_ctx = resolve_git_context(flags.str_opt("repo-root"))?;
    if !is_draft {
        if !auth_resolve {
            return Err(err_blocked_before_write(
                "PR_AUTH_REQUIRED",
                "Explicit --authorize-resolve is required to resolve a review thread (or use --draft)",
                Vec::new(),
            ));
        }
        assert_mutation_owner_allowed(&git_ctx, "resolve", flags.str_opt("repo-root"))?;
    }
    let Some(evidence_file) = flags.str_opt("evidence-file") else {
        return Err(err_blocked_before_write(
            "PR_VERIFY_REQUIRED",
            "--evidence-file (bound to repo, PR, HEAD, thread, fix commit, and canonical b3-verify-v1 receipt) is required",
            Vec::new(),
        ));
    };

    let evidence = parse_resolve_evidence(
        evidence_file,
        &git_ctx.repo_root,
        &repo.full,
        pr_number,
        &expected_head,
        &thread_id,
        &fix_commit,
    )?;
    let mut paths_to_verify = Vec::new();
    let mut seen_paths = BTreeSet::new();
    for p in std::iter::once(&evidence.target_path).chain(evidence.fixed_paths.iter()) {
        if seen_paths.insert(p.clone()) {
            paths_to_verify.push(p.clone());
        }
    }
    let guard_message = run_canonical_verify_check(
        &git_ctx.repo_root,
        &evidence.receipt_full_path,
        &expected_head,
        &evidence.checked_command,
        &paths_to_verify,
    )?;

    if is_draft {
        return Ok(pr_emit(
            JsonValue::obj(vec![
                ("status".to_string(), JsonValue::str("PR_DRAFT_OK")),
                ("action".to_string(), JsonValue::str("resolve")),
                ("mutated".to_string(), JsonValue::Bool(false)),
                ("repo".to_string(), JsonValue::str(&repo.full)),
                ("pr".to_string(), JsonValue::num_u64(pr_number)),
                ("expected_head".to_string(), JsonValue::str(&expected_head)),
                ("thread_id".to_string(), JsonValue::str(&thread_id)),
                ("fix_commit".to_string(), JsonValue::str(&fix_commit)),
                (
                    "evidence_basis".to_string(),
                    JsonValue::str(&evidence.basis),
                ),
                (
                    "target_path".to_string(),
                    JsonValue::str(&evidence.target_path),
                ),
                ("verify_check".to_string(), JsonValue::str(&guard_message)),
                ("committed_tree_verified".to_string(), JsonValue::Bool(true)),
            ]),
            EXIT_OK,
        ));
    }

    let state_path = resolve_canonical_state_path(&git_ctx.git_common_dir, &repo.full, pr_number)?;

    execute_guarded_mutation(
        &state_path,
        &repo,
        pr_number,
        &expected_head,
        "resolve",
        max_pages,
        |header| {
            let thread =
                fetch_single_review_thread(&repo.full, pr_number, &thread_id, max_pages, false)?;
            let Some(th) = thread else {
                let gen = gh_rest_get(
                    &format!("repos/{}/issues/comments/{thread_id}", repo.full),
                    true,
                )?;
                if let GhResponse::Data(Some(gd)) = gen {
                    let iurl = gd
                        .get("issue_url")
                        .and_then(JsonValue::as_str)
                        .unwrap_or("");
                    if iurl.ends_with(&format!("/issues/{pr_number}")) {
                        return Err(err_simple(
                            "PR_NOT_RESOLVABLE",
                            format!(
                                "Target {thread_id} is a general PR comment and cannot be resolved"
                            ),
                        ));
                    }
                }
                return Err(err_simple(
                    "PR_TARGET_MISMATCH",
                    format!(
                        "Review thread {thread_id} does not belong to {}#{pr_number}",
                        repo.full
                    ),
                ));
            };
            if th.path.is_empty() || evidence.target_path != th.path {
                let th_disp = if th.path.is_empty() {
                    "missing"
                } else {
                    &th.path
                };
                return Err(err_blocked_before_write(
                    "PR_VERIFY_REQUIRED",
                    format!(
                        "Evidence target_path ({}) does not match thread path ({th_disp})",
                        evidence.target_path
                    ),
                    Vec::new(),
                ));
            }
            if evidence.basis == "DUPLICATE_FIXED" {
                let primary = fetch_single_review_thread(
                    &repo.full,
                    pr_number,
                    &evidence.primary_thread_id,
                    max_pages,
                    false,
                )?;
                if !primary.as_ref().is_some_and(|p| p.is_resolved) {
                    return Err(err_blocked_before_write(
                        "PR_VERIFY_REQUIRED",
                        format!(
                            "DUPLICATE_FIXED primary_thread_id ({}) must exist on {}#{pr_number} and be resolved first",
                            evidence.primary_thread_id, repo.full
                        ),
                        Vec::new(),
                    ));
                }
            }

            let cmp = gh_rest_get(
                &format!(
                    "repos/{}/compare/{fix_commit}...{}",
                    repo.full, header.head_sha
                ),
                true,
            )?;
            let (cmp_ok, cmp_status, behind_by) = match cmp {
                GhResponse::Data(Some(d)) => {
                    let st = d
                        .get("status")
                        .and_then(JsonValue::as_str)
                        .unwrap_or("")
                        .to_string();
                    let bb = d.get("behind_by").and_then(JsonValue::as_i64).unwrap_or(-1);
                    (true, st, bb)
                }
                _ => (false, String::new(), -1),
            };
            if !cmp_ok || !(cmp_status == "identical" || (cmp_status == "ahead" && behind_by == 0))
            {
                return Err(err_blocked_before_write(
                    "PR_FIX_NOT_REMOTE",
                    format!(
                        "Fix commit {fix_commit} is not reachable in remote PR HEAD {}",
                        header.head_sha
                    ),
                    Vec::new(),
                ));
            }

            let commit_res =
                gh_rest_get(&format!("repos/{}/commits/{fix_commit}", repo.full), true)?;
            let mut touched = BTreeSet::new();
            let commit_found = match commit_res {
                GhResponse::Data(Some(d)) => {
                    if let Some(files) = d.get("files").and_then(JsonValue::as_array) {
                        for f in files {
                            if let Some(fnm) = f.get("filename").and_then(JsonValue::as_str) {
                                touched.insert(fnm.to_string());
                            }
                            if let Some(pnm) =
                                f.get("previous_filename").and_then(JsonValue::as_str)
                            {
                                touched.insert(pnm.to_string());
                            }
                        }
                    }
                    true
                }
                _ => false,
            };
            if !commit_found || !paths_to_verify.iter().all(|p| touched.contains(p)) {
                return Err(err_blocked_before_write(
                    "PR_VERIFY_REQUIRED",
                    format!(
                        "Remote fix commit {fix_commit} does not modify all verified paths ({})",
                        paths_to_verify.join(", ")
                    ),
                    Vec::new(),
                ));
            }

            if th.is_resolved {
                return Ok(PrepareResult::EarlyEmit {
                    payload: JsonValue::obj(vec![
                        ("status".to_string(), JsonValue::str("PR_ALREADY_RESOLVED")),
                        ("action".to_string(), JsonValue::str("resolve")),
                        ("mutated".to_string(), JsonValue::Bool(false)),
                        ("thread_id".to_string(), JsonValue::str(&thread_id)),
                        (
                            "verified_head".to_string(),
                            JsonValue::str(&header.head_sha),
                        ),
                    ]),
                    audit_record: Some(vec![
                        (
                            "op_id".to_string(),
                            JsonValue::str(format!("resolved-{thread_id}")),
                        ),
                        ("action".to_string(), JsonValue::str("resolve")),
                        ("status".to_string(), JsonValue::str("PR_ALREADY_RESOLVED")),
                        ("repo".to_string(), JsonValue::str(&repo.full)),
                        ("pr".to_string(), JsonValue::num_u64(pr_number)),
                        ("target_id".to_string(), JsonValue::str(&thread_id)),
                        ("fix_commit".to_string(), JsonValue::str(&fix_commit)),
                    ]),
                });
            }

            Ok(PrepareResult::Proceed {
                state: (),
                extra_ids: vec![("thread_id".to_string(), JsonValue::str(&thread_id))],
                pending_meta: vec![
                    ("target_id".to_string(), JsonValue::str(&thread_id)),
                    ("fix_commit".to_string(), JsonValue::str(&fix_commit)),
                ],
            })
        },
        || {
            let _ = run_canonical_verify_check(
                &git_ctx.repo_root,
                &evidence.receipt_full_path,
                &expected_head,
                &evidence.checked_command,
                &paths_to_verify,
            )?;
            Ok(())
        },
        |_prep, _header| {
            let m = "mutation($threadId: ID!) { resolveReviewThread(input: { threadId: $threadId }) { thread { id isResolved } } }";
            let vars = JsonValue::obj(vec![("threadId".to_string(), JsonValue::str(&thread_id))]);
            let res = gh_graphql(m, vars)?;
            let is_res = res
                .get("resolveReviewThread")
                .and_then(|r| r.get("thread"))
                .and_then(|t| t.get("isResolved"))
                .and_then(JsonValue::as_bool)
                .unwrap_or(false);
            if !is_res {
                return Err(err_simple(
                    "PR_API_ERROR",
                    "resolveReviewThread did not confirm isResolved=true",
                ));
            }
            Ok(MutationResult {
                created_id: Some(thread_id.clone()),
                require_id: false,
            })
        },
        |_prep, header, _created_id, pages| {
            let spec = VerifyRemoteSpec {
                kind: "resolve_thread",
                repo: &repo.full,
                pr: pr_number,
                viewer: &header.viewer,
                created_id: "",
                thread_id: &thread_id,
                expected_head: "",
                expected_body: None,
                expected_body_sha256: "",
                marker: "",
                event: "",
                expected_inline: &[],
            };
            verify_remote_object(&spec, pages)
        },
        |_prep, _header, _created_id, v_res| {
            JsonValue::obj(vec![
                ("status".to_string(), JsonValue::str("PR_RESOLVE_OK")),
                ("action".to_string(), JsonValue::str("resolve")),
                ("mutated".to_string(), JsonValue::Bool(true)),
                ("repo".to_string(), JsonValue::str(&repo.full)),
                ("pr".to_string(), JsonValue::num_u64(pr_number)),
                ("thread_id".to_string(), JsonValue::str(&thread_id)),
                ("fix_commit".to_string(), JsonValue::str(&fix_commit)),
                ("is_resolved".to_string(), JsonValue::Bool(true)),
                ("verify_check".to_string(), JsonValue::str(&guard_message)),
                ("committed_tree_verified".to_string(), JsonValue::Bool(true)),
                ("verified_remote".to_string(), JsonValue::Bool(true)),
                (
                    "verified_head".to_string(),
                    JsonValue::str(&v_res.post_head),
                ),
            ])
        },
    )
}

fn parse_and_validate_inline_json(
    inline_json_path: &str,
) -> Result<Vec<InlineCommentSpec>, PrExit> {
    let raw = read_safe_input_file(inline_json_path, "--inline-json", MAX_FILE_BYTES)?;
    let parsed = parse_json(&raw)
        .map_err(|_| err_simple("PR_INVALID_ARGS", "--inline-json is not valid JSON"))?;
    let Some(arr) = parsed.as_array() else {
        return Err(err_simple(
            "PR_INVALID_ARGS",
            "--inline-json must be a non-empty JSON array",
        ));
    };
    if arr.is_empty() {
        return Err(err_simple(
            "PR_INVALID_ARGS",
            "--inline-json must be a non-empty JSON array",
        ));
    }
    let mut specs = Vec::with_capacity(arr.len());
    for (idx, item) in arr.iter().enumerate() {
        if !item.is_object() {
            return Err(err_simple(
                "PR_INVALID_ARGS",
                format!("Inline finding[{idx}] must be an object"),
            ));
        }
        if item.get("status").and_then(JsonValue::as_str) != Some("CONFIRMED") {
            return Err(err_simple(
                "PR_INVALID_ARGS",
                format!("Inline finding[{idx}] rejected: status must be CONFIRMED"),
            ));
        }
        let severity = item
            .get("severity")
            .and_then(JsonValue::as_str)
            .unwrap_or("");
        if !matches!(severity, "CRITICAL" | "HIGH" | "MEDIUM" | "LOW") {
            return Err(err_simple(
                "PR_INVALID_ARGS",
                format!("Inline finding[{idx}] rejected: invalid severity"),
            ));
        }
        let p_raw = item.get("path").and_then(JsonValue::as_str).unwrap_or("");
        let p = validate_rel_path(p_raw, &format!("Inline finding[{idx}].path"))?;
        let line = match item.get("line").and_then(JsonValue::as_i64) {
            Some(n) if n >= 1 => n,
            _ => {
                return Err(err_simple(
                    "PR_INVALID_ARGS",
                    format!("Inline finding[{idx}] must have positive integer line"),
                ));
            }
        };
        let side = match item.get("side") {
            Some(v) if !matches!(v, JsonValue::Null) => v.to_text_string().unwrap_or_default(),
            _ => "RIGHT".to_string(),
        };
        if !matches!(side.as_str(), "RIGHT" | "LEFT") {
            return Err(err_simple(
                "PR_INVALID_ARGS",
                format!("Inline finding[{idx}] has invalid side (expected RIGHT|LEFT)"),
            ));
        }
        let title = item
            .get("title")
            .and_then(JsonValue::as_str)
            .unwrap_or("")
            .trim();
        let body = item
            .get("body")
            .and_then(JsonValue::as_str)
            .unwrap_or("")
            .trim();
        let fix = item
            .get("suggested_fix")
            .and_then(JsonValue::as_str)
            .unwrap_or("")
            .trim();
        if title.is_empty() || body.is_empty() || fix.is_empty() {
            return Err(err_simple(
                "PR_INVALID_ARGS",
                format!("Inline finding[{idx}] requires non-empty title, body, and suggested_fix"),
            ));
        }
        let formatted = format!("**[{severity}] — {title}**\n\n{body}\n\n**Suggested fix:** {fix}");
        if formatted.chars().count() > MAX_BODY_CHARS {
            return Err(err_simple(
                "PR_FILE_GUARD",
                format!("Inline finding[{idx}] exceeds {MAX_BODY_CHARS} chars"),
            ));
        }
        specs.push(InlineCommentSpec {
            path: p,
            line,
            side,
            body: formatted,
        });
    }
    Ok(specs)
}

struct CommentPrep {
    final_body: String,
    identity: OpIdentity,
}

fn handle_comment(flags: &ParsedFlags) -> Result<PrExit, PrExit> {
    let repo = validate_repo_flag(flags.str_opt("repo"))?;
    let pr_number = validate_pr_flag(flags.str_opt("pr"))?;
    let expected_head = validate_sha_flag(flags.str_opt("expected-head"), "--expected-head")?;
    let mode = flags.str_opt("mode").unwrap_or("");
    if !matches!(mode, "summary" | "inline" | "both") {
        return Err(err_simple(
            "PR_INVALID_ARGS",
            "Invalid --mode (expected summary|inline|both)",
        ));
    }
    let event = flags.str_opt("event").unwrap_or("COMMENT");
    if !matches!(event, "COMMENT" | "APPROVE" | "REQUEST_CHANGES") {
        return Err(err_simple(
            "PR_INVALID_ARGS",
            "Invalid --event (expected COMMENT|APPROVE|REQUEST_CHANGES)",
        ));
    }
    let auth_review_event = flags.str_opt("authorize-review-event");
    if let Some(are) = auth_review_event {
        if !matches!(are, "APPROVE" | "REQUEST_CHANGES") {
            return Err(err_simple(
                "PR_INVALID_ARGS",
                "Invalid --authorize-review-event",
            ));
        }
        if event == "COMMENT" {
            return Err(err_simple(
                "PR_INVALID_ARGS",
                "--authorize-review-event cannot be set when --event is COMMENT",
            ));
        }
    }
    let explicit_key = validate_key_flag(flags.str_opt("idempotency-key"))?;
    let max_pages = validate_max_pages_flag(flags.str_opt("max-pages"))?;
    let is_draft = flags.bool_flag("draft");
    let auth_write = flags.bool_flag("authorize-write");
    if is_draft && (auth_write || auth_review_event.is_some()) {
        return Err(err_simple(
            "PR_INVALID_ARGS",
            "--draft cannot be combined with --authorize-write or --authorize-review-event",
        ));
    }

    let summary_body = if mode == "summary" || mode == "both" {
        let Some(sum_file) = flags.str_opt("summary-file") else {
            return Err(err_simple(
                "PR_INVALID_ARGS",
                format!("--summary-file is required for --mode {mode}"),
            ));
        };
        let norm = normalize_text(&read_safe_input_file(
            sum_file,
            "--summary-file",
            MAX_FILE_BYTES,
        )?);
        if norm.is_empty() {
            return Err(err_simple("PR_INVALID_ARGS", "--summary-file is empty"));
        }
        norm
    } else if flags.str_opt("summary-file").is_some() {
        return Err(err_simple(
            "PR_INVALID_ARGS",
            "--summary-file is not allowed with --mode inline",
        ));
    } else {
        String::new()
    };

    let inline_comments = if mode == "inline" || mode == "both" {
        let Some(inl_file) = flags.str_opt("inline-json") else {
            return Err(err_simple(
                "PR_INVALID_ARGS",
                format!("--inline-json is required for --mode {mode}"),
            ));
        };
        parse_and_validate_inline_json(inl_file)?
    } else if flags.str_opt("inline-json").is_some() {
        return Err(err_simple(
            "PR_INVALID_ARGS",
            "--inline-json is not allowed with --mode summary",
        ));
    } else {
        Vec::new()
    };

    let inline_json_items: Vec<JsonValue> = inline_comments
        .iter()
        .map(InlineCommentSpec::to_json)
        .collect();
    let canonical_payload = JsonValue::obj(vec![
        ("summary".to_string(), JsonValue::str(&summary_body)),
        (
            "inline".to_string(),
            JsonValue::Array(inline_json_items.clone()),
        ),
    ])
    .to_json_string();

    if is_draft {
        let id_obj = compute_operation_identity(
            &repo.full,
            pr_number,
            "draft",
            "comment",
            "pr",
            &pr_number.to_string(),
            &expected_head,
            mode,
            event,
            &canonical_payload,
            &explicit_key,
        );
        let preview = append_marker(&summary_body, &id_obj.marker);
        if preview.chars().count() > MAX_BODY_CHARS {
            return Err(err_simple(
                "PR_FILE_GUARD",
                format!("Summary body exceeds {MAX_BODY_CHARS} chars"),
            ));
        }
        return Ok(pr_emit(
            JsonValue::obj(vec![
                ("status".to_string(), JsonValue::str("PR_DRAFT_OK")),
                ("action".to_string(), JsonValue::str("comment")),
                ("mutated".to_string(), JsonValue::Bool(false)),
                ("repo".to_string(), JsonValue::str(&repo.full)),
                ("pr".to_string(), JsonValue::num_u64(pr_number)),
                ("expected_head".to_string(), JsonValue::str(&expected_head)),
                ("mode".to_string(), JsonValue::str(mode)),
                ("event".to_string(), JsonValue::str(event)),
                ("idempotency_key".to_string(), JsonValue::str(&id_obj.key)),
                (
                    "operation_hash".to_string(),
                    JsonValue::str(&id_obj.op_hash),
                ),
                ("summary_preview".to_string(), JsonValue::str(preview)),
                (
                    "inline_count".to_string(),
                    JsonValue::num_u64(inline_comments.len() as u64),
                ),
                (
                    "inline_preview".to_string(),
                    JsonValue::Array(inline_json_items),
                ),
            ]),
            EXIT_OK,
        ));
    }

    if !auth_write {
        return Err(err_blocked_before_write(
            "PR_AUTH_REQUIRED",
            "Explicit --authorize-write is required to publish PR comments (or use --draft)",
            Vec::new(),
        ));
    }
    if event != "COMMENT" && auth_review_event != Some(event) {
        return Err(err_blocked_before_write(
            "PR_EVENT_UNAUTHORIZED",
            format!("Review event {event} requires matching --authorize-review-event {event}"),
            Vec::new(),
        ));
    }

    let transport = if mode == "summary" && event == "COMMENT" {
        "issue_comment"
    } else {
        "pull_review"
    };
    let git_ctx = resolve_git_context(flags.str_opt("repo-root"))?;
    assert_mutation_owner_allowed(&git_ctx, "comment", flags.str_opt("repo-root"))?;
    let state_path = resolve_canonical_state_path(&git_ctx.git_common_dir, &repo.full, pr_number)?;

    execute_guarded_mutation(
        &state_path,
        &repo,
        pr_number,
        &expected_head,
        "comment",
        max_pages,
        |header| {
            if !inline_comments.is_empty() {
                let pr_files = fetch_rest_paginated(
                    &format!("repos/{}/pulls/{pr_number}/files", repo.full),
                    max_pages,
                )?;
                let mut file_map: HashMap<String, &JsonValue> = HashMap::new();
                for f in &pr_files {
                    if let Some(name) = f.get("filename").and_then(JsonValue::as_str) {
                        if !name.is_empty() {
                            file_map.insert(name.to_string(), f);
                        }
                    }
                }
                for ic in &inline_comments {
                    let Some(f_obj) = file_map.get(&ic.path) else {
                        return Err(err_blocked_before_write(
                            "PR_TARGET_MISMATCH",
                            format!(
                                "Inline path {} is not in PR {}#{pr_number} changed files",
                                ic.path, repo.full
                            ),
                            Vec::new(),
                        ));
                    };
                    let anchors =
                        parse_unified_diff_anchors(f_obj.get("patch").and_then(JsonValue::as_str))
                            .map_err(|reason| {
                                err_blocked_before_write(
                                    "PR_DIFF_UNAVAILABLE",
                                    format!(
                                        "Diff patch for {} cannot be validated ({reason}); cannot anchor {}:{} ({})",
                                        ic.path, ic.path, ic.line, ic.side
                                    ),
                                    Vec::new(),
                                )
                            })?;
                    let valid_set = if ic.side == "LEFT" {
                        &anchors.left_lines
                    } else {
                        &anchors.right_lines
                    };
                    if !valid_set.contains(&ic.line) {
                        let mut fail_err = err_blocked_before_write(
                            "PR_INVALID_ANCHOR",
                            format!(
                                "Inline anchor {}:{} ({}) is not present in PR diff hunks",
                                ic.path, ic.line, ic.side
                            ),
                            Vec::new(),
                        );
                        fail_err.code = EXIT_ERROR;
                        return Err(fail_err);
                    }
                }
            }

            let pr_id_str = pr_number.to_string();
            let identity = compute_operation_identity(
                &repo.full,
                pr_number,
                &header.viewer,
                "comment",
                "pr",
                &pr_id_str,
                &expected_head,
                mode,
                event,
                &canonical_payload,
                &explicit_key,
            );
            let final_body = append_marker(&summary_body, &identity.marker);
            if final_body.chars().count() > MAX_BODY_CHARS {
                return Err(err_simple(
                    "PR_FILE_GUARD",
                    format!("Summary body exceeds {MAX_BODY_CHARS} chars"),
                ));
            }

            let raw_issue = fetch_rest_paginated(
                &format!("repos/{}/issues/{pr_number}/comments", repo.full),
                max_pages,
            )?;
            let raw_reviews = fetch_rest_paginated(
                &format!("repos/{}/pulls/{pr_number}/reviews", repo.full),
                max_pages,
            )?;
            let mut candidates = Vec::with_capacity(raw_issue.len() + raw_reviews.len());
            for c in &raw_issue {
                candidates.push(IdemCandidate {
                    id: c
                        .get("id")
                        .and_then(JsonValue::to_text_string)
                        .unwrap_or_default(),
                    kind: "issue_comment".to_string(),
                    author: c
                        .get("user")
                        .and_then(|u| u.get("login"))
                        .and_then(JsonValue::as_str)
                        .unwrap_or("")
                        .to_string(),
                    body: c
                        .get("body")
                        .and_then(JsonValue::as_str)
                        .unwrap_or("")
                        .to_string(),
                });
            }
            for r in &raw_reviews {
                candidates.push(IdemCandidate {
                    id: r
                        .get("id")
                        .and_then(JsonValue::to_text_string)
                        .unwrap_or_default(),
                    kind: "pull_review".to_string(),
                    author: r
                        .get("user")
                        .and_then(|u| u.get("login"))
                        .and_then(JsonValue::as_str)
                        .unwrap_or("")
                        .to_string(),
                    body: r
                        .get("body")
                        .and_then(JsonValue::as_str)
                        .unwrap_or("")
                        .to_string(),
                });
            }

            let idem = check_idempotency_with_revalidation(
                &candidates,
                &header.viewer,
                &identity,
                |cand, exp_marker| {
                    if cand.kind != transport {
                        return Ok(VerifyRemoteOutcome {
                            found: true,
                            ok: false,
                            is_resolved: false,
                            post_state: String::new(),
                            post_head: String::new(),
                            reason: format!("transport_mismatch({}!={transport})", cand.kind),
                        });
                    }
                    let spec = VerifyRemoteSpec {
                        kind: transport,
                        repo: &repo.full,
                        pr: pr_number,
                        viewer: &header.viewer,
                        created_id: &cand.id,
                        thread_id: "",
                        expected_head: &expected_head,
                        expected_body: Some(&summary_body),
                        expected_body_sha256: "",
                        marker: exp_marker,
                        event,
                        expected_inline: &inline_comments,
                    };
                    verify_remote_object(&spec, max_pages)
                },
            )?;

            match idem {
                IdemStatus::Collision { existing_id } => Err(err_blocked_before_write(
                    "PR_KEY_COLLISION",
                    format!(
                        "Idempotency key {} already used for a different comment/review ({existing_id})",
                        identity.key
                    ),
                    vec![
                        ("existing_id".to_string(), JsonValue::str(existing_id)),
                        ("key".to_string(), JsonValue::str(&identity.key)),
                    ],
                )),
                IdemStatus::RemoteMismatch {
                    existing_id,
                    reason,
                } => Err(err_blocked_before_write(
                    "PR_REMOTE_STATE_MISMATCH",
                    format!(
                        "Existing remote {transport} {existing_id} with marker {} is inconsistent ({reason})",
                        identity.key
                    ),
                    vec![
                        ("existing_id".to_string(), JsonValue::str(existing_id)),
                        ("key".to_string(), JsonValue::str(&identity.key)),
                    ],
                )),
                IdemStatus::Match { existing_id } => Ok(PrepareResult::EarlyEmit {
                    payload: JsonValue::obj(vec![
                        ("status".to_string(), JsonValue::str("PR_IDEMPOTENT_SKIP")),
                        ("action".to_string(), JsonValue::str("comment")),
                        ("mutated".to_string(), JsonValue::Bool(false)),
                        ("mode".to_string(), JsonValue::str(mode)),
                        ("key".to_string(), JsonValue::str(&identity.key)),
                        (
                            "operation_hash".to_string(),
                            JsonValue::str(&identity.op_hash),
                        ),
                        ("existing_id".to_string(), JsonValue::str(&existing_id)),
                    ]),
                    audit_record: Some(vec![
                        (
                            "op_id".to_string(),
                            JsonValue::str(format!("skip-{}", identity.op_hash)),
                        ),
                        ("action".to_string(), JsonValue::str("comment")),
                        ("status".to_string(), JsonValue::str("PR_IDEMPOTENT_SKIP")),
                        ("repo".to_string(), JsonValue::str(&repo.full)),
                        ("pr".to_string(), JsonValue::num_u64(pr_number)),
                        ("mode".to_string(), JsonValue::str(mode)),
                        ("key".to_string(), JsonValue::str(&identity.key)),
                        ("op_hash".to_string(), JsonValue::str(&identity.op_hash)),
                        ("existing_id".to_string(), JsonValue::str(existing_id)),
                    ]),
                }),
                IdemStatus::None => {
                    let body_sha = sha256_utf8_hex(&strip_markers(&summary_body));
                    Ok(PrepareResult::Proceed {
                        pending_meta: vec![
                            ("mode".to_string(), JsonValue::str(mode)),
                            ("event".to_string(), JsonValue::str(event)),
                            ("transport".to_string(), JsonValue::str(transport)),
                            ("key".to_string(), JsonValue::str(&identity.key)),
                            ("op_hash".to_string(), JsonValue::str(&identity.op_hash)),
                            ("body_sha256".to_string(), JsonValue::str(body_sha)),
                            (
                                "expected_inline".to_string(),
                                JsonValue::Array(inline_json_items),
                            ),
                        ],
                        extra_ids: Vec::new(),
                        state: CommentPrep {
                            final_body,
                            identity,
                        },
                    })
                }
            }
        },
        || Ok(()),
        |prep, _header| {
            if transport == "issue_comment" {
                let payload =
                    JsonValue::obj(vec![("body".to_string(), JsonValue::str(&prep.final_body))]);
                let res = gh_rest_post(
                    &format!("repos/{}/issues/{pr_number}/comments", repo.full),
                    &payload,
                )?;
                let cid = res
                    .as_ref()
                    .and_then(|v| v.get("id"))
                    .and_then(JsonValue::to_text_string);
                Ok(MutationResult {
                    created_id: cid,
                    require_id: true,
                })
            } else {
                let mut entries = vec![
                    ("commit_id".to_string(), JsonValue::str(&expected_head)),
                    ("event".to_string(), JsonValue::str(event)),
                    ("body".to_string(), JsonValue::str(&prep.final_body)),
                ];
                if !inline_comments.is_empty() {
                    entries.push((
                        "comments".to_string(),
                        JsonValue::Array(
                            inline_comments
                                .iter()
                                .map(InlineCommentSpec::to_json)
                                .collect(),
                        ),
                    ));
                }
                let payload = JsonValue::Object(entries);
                let res = gh_rest_post(
                    &format!("repos/{}/pulls/{pr_number}/reviews", repo.full),
                    &payload,
                )?;
                let cid = res
                    .as_ref()
                    .and_then(|v| v.get("id"))
                    .and_then(JsonValue::to_text_string);
                Ok(MutationResult {
                    created_id: cid,
                    require_id: true,
                })
            }
        },
        |prep, header, created_id, pages| {
            let spec = VerifyRemoteSpec {
                kind: transport,
                repo: &repo.full,
                pr: pr_number,
                viewer: &header.viewer,
                created_id,
                thread_id: "",
                expected_head: &expected_head,
                expected_body: Some(&summary_body),
                expected_body_sha256: "",
                marker: &prep.identity.marker,
                event,
                expected_inline: &inline_comments,
            };
            verify_remote_object(&spec, pages)
        },
        |prep, _header, created_id, v_res| {
            JsonValue::obj(vec![
                ("status".to_string(), JsonValue::str("PR_COMMENT_OK")),
                ("action".to_string(), JsonValue::str("comment")),
                ("mutated".to_string(), JsonValue::Bool(true)),
                ("repo".to_string(), JsonValue::str(&repo.full)),
                ("pr".to_string(), JsonValue::num_u64(pr_number)),
                ("mode".to_string(), JsonValue::str(mode)),
                ("event".to_string(), JsonValue::str(event)),
                ("transport".to_string(), JsonValue::str(transport)),
                (
                    "created_id".to_string(),
                    JsonValue::str(created_id.unwrap_or("")),
                ),
                (
                    "idempotency_key".to_string(),
                    JsonValue::str(&prep.identity.key),
                ),
                (
                    "operation_hash".to_string(),
                    JsonValue::str(&prep.identity.op_hash),
                ),
                (
                    "inline_count".to_string(),
                    JsonValue::num_u64(inline_comments.len() as u64),
                ),
                ("verified_remote".to_string(), JsonValue::Bool(true)),
                (
                    "verified_head".to_string(),
                    JsonValue::str(&v_res.post_head),
                ),
            ])
        },
    )
}

/// Entrypoint for `b3 pr <fetch|reconcile|reply|resolve|comment>`.
/// Always returns structured single-line JSON on stdout (even on errors) and exit code 0/1/2.
pub fn run(subcommand: &str, args: &[String]) -> Result<(String, i32), B3Error> {
    let outcome = (|| -> Result<PrExit, PrExit> {
        let flags = parse_cli_flags(subcommand, args)?;
        match subcommand {
            "fetch" => handle_fetch(&flags),
            "reconcile" => handle_reconcile(&flags),
            "reply" => handle_reply(&flags),
            "resolve" => handle_resolve(&flags),
            "comment" => handle_comment(&flags),
            other => Err(err_simple(
                "PR_INVALID_ARGS",
                format!(
                    "Unknown subcommand: {other} (expected: fetch, reply, resolve, comment, reconcile)"
                ),
            )),
        }
    })();

    match outcome {
        Ok(ex) => Ok((ex.payload.to_json_string(), ex.code)),
        Err(ex) => Err(fail(ex.payload.to_json_string(), ex.code)),
    }
}
