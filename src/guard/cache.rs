use std::collections::HashMap;
use std::path::{Path, PathBuf};

use crate::error::{fail, B3Error};
use crate::fs::{
    has_control_chars, is_reparse_or_symlink, normalize_path_value, normalize_repo_root,
    sha256_bytes_hex, sort_ordinal, test_checkpoint_path, test_contained_repo_path,
    test_path_match, test_secret_path, write_atomic_lf,
};
use crate::git::{
    is_hex40, merge_base_is_ancestor, run_git, run_git_paths_z, test_git_mid_operation, GitZMode,
};
use crate::guard::verify::{format_utc_iso8601_now, get_tree_fingerprint};

fn is_valid_context_scope_id(val: &str) -> bool {
    if val.is_empty() || val.len() > 80 {
        return false;
    }
    if !val
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'/' | b'-'))
    {
        return false;
    }
    if val == "." || val.starts_with('/') || val.ends_with('/') || val.contains("//") {
        return false;
    }
    !val.split('/').any(|seg| seg == "." || seg == "..")
}

enum CheckpointFileStatus {
    Invalid,
    SymlinkOrDir,
    Ok { rel: String, full: PathBuf },
}

fn check_checkpoint_file_path(root: &Path, path_arg: &str) -> CheckpointFileStatus {
    if path_arg.is_empty()
        || has_control_chars(path_arg)
        || path_arg.trim().is_empty()
        || path_arg.ends_with(' ')
    {
        return CheckpointFileStatus::Invalid;
    }
    let trimmed = path_arg.trim();
    if trimmed.contains(':') {
        return CheckpointFileStatus::Invalid;
    }
    let raw_slash = trimmed.replace('\\', "/");
    if raw_slash.is_empty() || raw_slash.ends_with('/') {
        return CheckpointFileStatus::Invalid;
    }
    let p = normalize_path_value(trimmed);
    if p.is_empty()
        || p == "."
        || p.starts_with('/')
        || p.starts_with('~')
        || p.contains(':')
        || p.contains("//")
        || p.split('/').any(|seg| seg == "." || seg == "..")
    {
        return CheckpointFileStatus::Invalid;
    }
    for seg in p.split('/') {
        if seg.is_empty() || seg.ends_with('.') || seg.ends_with(' ') {
            return CheckpointFileStatus::Invalid;
        }
    }
    let valid_b3 = p
        .strip_prefix(".b3/ship/")
        .or_else(|| p.strip_prefix(".b3/research-ship/"))
        .is_some_and(|rest| !rest.is_empty());
    if !valid_b3 || test_secret_path(&p) {
        return CheckpointFileStatus::Invalid;
    }
    let Some((full, rel)) = test_contained_repo_path(root, &p) else {
        return CheckpointFileStatus::SymlinkOrDir;
    };
    if full.is_dir() || is_reparse_or_symlink(&full) {
        return CheckpointFileStatus::SymlinkOrDir;
    }
    CheckpointFileStatus::Ok { rel, full }
}

fn split_strict_paths(
    root: &Path,
    csv: &str,
    allow_empty_sentinel: bool,
    block_b3_and_secrets: bool,
) -> Result<Vec<String>, String> {
    if csv.is_empty() {
        return if allow_empty_sentinel {
            Ok(Vec::new())
        } else {
            Err("<empty>".to_string())
        };
    }
    if has_control_chars(csv) {
        return Err(csv.to_string());
    }
    let cleaned = csv.trim();
    if allow_empty_sentinel && (cleaned.is_empty() || csv == "none" || csv == "[]") {
        return Ok(Vec::new());
    }
    if cleaned.is_empty() {
        return Err("<empty>".to_string());
    }

    let mut list = Vec::new();
    for raw_part in csv.split(',') {
        let tok = raw_part.trim_start_matches(' ');
        if tok.is_empty() {
            return Err("<empty>".to_string());
        }
        if tok == "none"
            || tok.starts_with('-')
            || tok.contains(':')
            || tok.contains('*')
            || tok.contains('?')
            || tok.contains('[')
            || tok.contains(']')
        {
            return Err(tok.to_string());
        }
        let Some((_, rel)) = test_contained_repo_path(root, tok) else {
            return Err(tok.to_string());
        };
        if rel.is_empty()
            || rel == "."
            || rel.starts_with('-')
            || rel.contains("//")
            || rel
                .split('/')
                .any(|seg| seg == "." || seg.eq_ignore_ascii_case(".git"))
        {
            return Err(tok.to_string());
        }
        if block_b3_and_secrets
            && (rel
                .split('/')
                .next()
                .is_some_and(|seg| seg.eq_ignore_ascii_case(".b3"))
                || test_secret_path(&rel))
        {
            return Err(tok.to_string());
        }
        list.push(rel);
    }
    if list.is_empty() && !allow_empty_sentinel {
        return Err("<empty>".to_string());
    }
    Ok(sort_ordinal(list, false))
}

fn ignore_overlaps_paths(ign_paths: &[String], target_paths: &[String]) -> bool {
    if ign_paths.is_empty() || target_paths.is_empty() {
        return false;
    }
    for p in target_paths {
        if p.is_empty() {
            continue;
        }
        for ign in ign_paths {
            if ign.is_empty() {
                continue;
            }
            if p == ign || p.starts_with(&format!("{ign}/")) || ign.starts_with(&format!("{p}/")) {
                return true;
            }
        }
    }
    false
}

fn resolve_strict_commit_sha(root: &Path, rev: &str) -> Result<Option<String>, B3Error> {
    let r = rev.trim();
    if r.is_empty() || r.starts_with('-') || r.chars().any(|c| c.is_whitespace()) {
        return Ok(None);
    }
    let no_env: [(&str, &str); 0] = [];
    let spec = format!("{r}^{{commit}}");
    let res = run_git(
        root,
        &["rev-parse", "--verify", "--quiet", &spec],
        &no_env,
        None,
    )?;
    if res.exit_code != 0 {
        return Ok(None);
    }
    let sha = String::from_utf8_lossy(&res.stdout).trim().to_string();
    if !is_hex40(&sha) {
        return Ok(None);
    }
    Ok(Some(sha))
}

fn is_ignored_cache_path(p: &str, ign_paths: &[String]) -> bool {
    test_checkpoint_path(p) || (!ign_paths.is_empty() && test_path_match(p, ign_paths))
}

fn test_graph_index_fresh(
    root: &Path,
    graph_sha: &str,
    live_head_sha: &str,
    probe_paths: &[String],
    ign_paths: &[String],
) -> Result<bool, B3Error> {
    if graph_sha != live_head_sha {
        return Ok(false);
    }
    let no_env: [(&str, &str); 0] = [];
    if !probe_paths.is_empty() {
        let mut w_args: Vec<String> = vec![
            "diff".into(),
            "--no-ext-diff".into(),
            "--no-renames".into(),
            "--name-only".into(),
            "--ignore-submodules=none".into(),
            "-z".into(),
            graph_sha.into(),
            "--".into(),
        ];
        w_args.extend(probe_paths.iter().cloned());
        let w_list = run_git_paths_z(root, &w_args, GitZMode::Names, "CONTEXT_ERROR", &no_env)?;

        let mut c_args: Vec<String> = vec![
            "diff".into(),
            "--no-ext-diff".into(),
            "--no-renames".into(),
            "--cached".into(),
            "--name-only".into(),
            "--ignore-submodules=none".into(),
            "-z".into(),
            graph_sha.into(),
            "--".into(),
        ];
        c_args.extend(probe_paths.iter().cloned());
        let c_list = run_git_paths_z(root, &c_args, GitZMode::Names, "CONTEXT_ERROR", &no_env)?;

        let mut u_args: Vec<String> = vec![
            "ls-files".into(),
            "--others".into(),
            "--exclude-standard".into(),
            "-z".into(),
            "--".into(),
        ];
        u_args.extend(probe_paths.iter().cloned());
        let u_list = run_git_paths_z(root, &u_args, GitZMode::Names, "CONTEXT_ERROR", &no_env)?;

        for p in w_list.into_iter().chain(c_list).chain(u_list) {
            if p.is_empty() || is_ignored_cache_path(&p, ign_paths) {
                continue;
            }
            return Ok(false);
        }
        return Ok(true);
    }

    let st_res = run_git(
        root,
        &[
            "status",
            "--porcelain",
            "--untracked-files=all",
            "--ignore-submodules=none",
            "-z",
        ],
        &no_env,
        None,
    )?;
    if st_res.exit_code != 0 {
        return Err(fail("CONTEXT_ERROR: git status failed", 1));
    }
    let mut records: Vec<&[u8]> = st_res.stdout.split(|&b| b == 0).collect();
    if matches!(records.last(), Some(last) if last.is_empty()) {
        records.pop();
    }
    let mut i = 0usize;
    while i < records.len() {
        let rec_bytes = records[i];
        i += 1;
        if rec_bytes.is_empty() {
            continue;
        }
        let Ok(rec) = std::str::from_utf8(rec_bytes) else {
            return Ok(false);
        };
        if rec.len() < 4 {
            return Ok(false);
        }
        let xy = rec.as_bytes();
        let p1 = rec[3..].trim_end_matches('/');
        if p1.is_empty() {
            return Ok(false);
        }
        let p1_ign = is_ignored_cache_path(p1, ign_paths);
        if xy[0] == b'R' || xy[0] == b'C' || xy[1] == b'R' || xy[1] == b'C' {
            if i >= records.len() {
                return Ok(false);
            }
            let Ok(p2_raw) = std::str::from_utf8(records[i]) else {
                return Ok(false);
            };
            i += 1;
            let p2 = p2_raw.trim_end_matches('/');
            if p2.is_empty() {
                return Ok(false);
            }
            let p2_ign = is_ignored_cache_path(p2, ign_paths);
            if !(p1_ign && p2_ign) {
                return Ok(false);
            }
        } else if !p1_ign {
            return Ok(false);
        }
    }
    Ok(true)
}

fn sha256_file_for_context(path: &Path) -> Result<String, B3Error> {
    let bytes =
        std::fs::read(path).map_err(|_| fail("CONTEXT_ERROR: sha256 computation failed", 1))?;
    Ok(sha256_bytes_hex(&bytes))
}

fn valid_timestamp_utc(ts: &str) -> bool {
    let b = ts.as_bytes();
    if b.len() != 20 {
        return false;
    }
    b[4] == b'-'
        && b[7] == b'-'
        && b[10] == b'T'
        && b[13] == b':'
        && b[16] == b':'
        && b[19] == b'Z'
        && [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18]
            .into_iter()
            .all(|idx| b[idx].is_ascii_digit())
}

/// Executes `b3 guard context-cache`.
#[allow(clippy::too_many_arguments)]
pub fn run(
    repo_root_raw: &str,
    action: &str,
    cache_path: &str,
    scope_id: &str,
    anchor_paths: &str,
    scope_paths: &str,
    graph_index_sha: &str,
    summary_ref: &str,
    ignore_dirty_paths: &str,
) -> Result<(String, i32), B3Error> {
    for raw_arg in [
        action,
        cache_path,
        scope_id,
        anchor_paths,
        scope_paths,
        graph_index_sha,
        summary_ref,
        ignore_dirty_paths,
    ] {
        if has_control_chars(raw_arg) {
            return Err(fail("CONTEXT_ERROR: control characters not allowed", 1));
        }
    }
    let act = action.trim();
    if act != "record" && act != "check" {
        return Err(fail("CONTEXT_ERROR: invalid action", 1));
    }

    let repo_root = normalize_repo_root(repo_root_raw)?;
    if test_git_mid_operation(&repo_root).is_some() {
        return Err(fail("CONTEXT_ERROR: mid-operation git state", 1));
    }
    let live_head_sha = resolve_strict_commit_sha(&repo_root, "HEAD")?
        .ok_or_else(|| fail("CONTEXT_ERROR: invalid HEAD", 1))?;

    let cache_spec = check_checkpoint_file_path(&repo_root, cache_path);

    if act == "record" {
        let CheckpointFileStatus::Ok {
            rel: cache_rel,
            full: cache_full,
        } = cache_spec
        else {
            return Err(fail("CONTEXT_ERROR: invalid cache_path", 1));
        };
        let scope_val = scope_id.trim();
        if !is_valid_context_scope_id(scope_val) {
            return Err(fail("CONTEXT_ERROR: invalid scope_id", 1));
        }

        let anc_arr = split_strict_paths(&repo_root, anchor_paths, true, true)
            .map_err(|bad| fail(format!("CONTEXT_ERROR: invalid path {bad}"), 1))?;
        let rec_scope_arr = split_strict_paths(&repo_root, scope_paths, true, true)
            .map_err(|bad| fail(format!("CONTEXT_ERROR: invalid path {bad}"), 1))?;
        let ign_arr = split_strict_paths(&repo_root, ignore_dirty_paths, true, false)
            .map_err(|_| fail("CONTEXT_ERROR: invalid ignore path", 1))?;
        if ignore_overlaps_paths(&ign_arr, &anc_arr)
            || ignore_overlaps_paths(&ign_arr, &rec_scope_arr)
        {
            return Err(fail("CONTEXT_ERROR: invalid ignore path", 1));
        }

        let graph_trim = graph_index_sha.trim();
        let graph_val = if !graph_trim.is_empty() && graph_trim != "none" {
            resolve_strict_commit_sha(&repo_root, graph_trim)?
                .ok_or_else(|| fail("CONTEXT_ERROR: invalid graph_index_sha", 1))?
        } else {
            "none".to_string()
        };

        if anc_arr.is_empty() && graph_val == "none" {
            return Err(fail(
                "CONTEXT_ERROR: empty cache (anchor_paths or graph_index_sha required)",
                1,
            ));
        }

        let sum_trim = summary_ref.trim();
        let (sum_ref_val, sum_sha_val) = if !sum_trim.is_empty() && sum_trim != "none" {
            let CheckpointFileStatus::Ok { rel, full } =
                check_checkpoint_file_path(&repo_root, sum_trim)
            else {
                return Err(fail("CONTEXT_ERROR: invalid summary_ref", 1));
            };
            if !full.is_file() || is_reparse_or_symlink(&full) {
                return Err(fail("CONTEXT_ERROR: missing summary_ref", 1));
            }
            let sha = sha256_file_for_context(&full)?;
            (rel, sha)
        } else {
            ("none".to_string(), "none".to_string())
        };

        let (anchor_paths_val, anchor_hash_val) = if !anc_arr.is_empty() {
            let fp = get_tree_fingerprint(&repo_root, &anc_arr, &ign_arr, "")?;
            (anc_arr.join(","), fp.tree_hash)
        } else {
            ("none".to_string(), "none".to_string())
        };

        let ts_utc = format_utc_iso8601_now();
        let body = [
            "schema=b3-context-v1".to_string(),
            format!("scope_id={scope_val}"),
            format!("head_sha={live_head_sha}"),
            format!("anchor_paths={anchor_paths_val}"),
            format!("anchor_hash={anchor_hash_val}"),
            format!("graph_index_sha={graph_val}"),
            format!("summary_ref={sum_ref_val}"),
            format!("summary_sha256={sum_sha_val}"),
            format!("timestamp_utc={ts_utc}"),
        ]
        .join("\n")
            + "\n";
        write_atomic_lf(&cache_full, &body)?;
        return Ok((
            format!(
                "CONTEXT_RECORDED: {cache_rel} scope={scope_val} head={live_head_sha} anchor_hash={anchor_hash_val} graph_index_sha={graph_val}"
            ),
            0,
        ));
    }

    // check
    let (cache_rel, cache_full) = match cache_spec {
        CheckpointFileStatus::Invalid => return Err(fail("CONTEXT_ERROR: invalid cache_path", 1)),
        CheckpointFileStatus::SymlinkOrDir => {
            return Err(fail("CONTEXT_CORRUPT: invalid cache_path", 1))
        }
        CheckpointFileStatus::Ok { rel, full } => (rel, full),
    };

    let caller_scope = scope_id.trim();
    if !caller_scope.is_empty() && !is_valid_context_scope_id(caller_scope) {
        return Err(fail("CONTEXT_ERROR: invalid scope_id", 1));
    }

    let mut has_caller_anchor = false;
    let mut caller_anchor_arr = Vec::new();
    let mut caller_anchor_csv = "none".to_string();
    if !anchor_paths.trim().is_empty() {
        has_caller_anchor = true;
        caller_anchor_arr = split_strict_paths(&repo_root, anchor_paths, true, true)
            .map_err(|bad| fail(format!("CONTEXT_ERROR: invalid path {bad}"), 1))?;
        if !caller_anchor_arr.is_empty() {
            caller_anchor_csv = caller_anchor_arr.join(",");
        }
    }

    let scope_arr = split_strict_paths(&repo_root, scope_paths, true, true)
        .map_err(|bad| fail(format!("CONTEXT_ERROR: invalid path {bad}"), 1))?;
    let ign_arr = split_strict_paths(&repo_root, ignore_dirty_paths, true, false)
        .map_err(|_| fail("CONTEXT_ERROR: invalid ignore path", 1))?;

    let mut has_caller_graph = false;
    let mut caller_graph_val = "none".to_string();
    let caller_graph_trim = graph_index_sha.trim();
    if !caller_graph_trim.is_empty() {
        has_caller_graph = true;
        if caller_graph_trim != "none" {
            caller_graph_val = resolve_strict_commit_sha(&repo_root, caller_graph_trim)?
                .ok_or_else(|| fail("CONTEXT_ERROR: invalid graph_index_sha", 1))?;
        }
    }

    let mut has_caller_summary = false;
    let mut caller_summary_val = "none".to_string();
    let sum_raw_trim = summary_ref.trim();
    if !sum_raw_trim.is_empty() {
        has_caller_summary = true;
        if sum_raw_trim != "none" {
            let CheckpointFileStatus::Ok { rel, .. } =
                check_checkpoint_file_path(&repo_root, sum_raw_trim)
            else {
                return Err(fail("CONTEXT_ERROR: invalid summary_ref", 1));
            };
            caller_summary_val = rel;
        }
    }

    if (has_caller_anchor && ignore_overlaps_paths(&ign_arr, &caller_anchor_arr))
        || ignore_overlaps_paths(&ign_arr, &scope_arr)
    {
        return Err(fail("CONTEXT_ERROR: invalid ignore path", 1));
    }

    if !cache_full.is_file() {
        return Err(fail(format!("CONTEXT_MISSING: {cache_rel}"), 1));
    }
    if is_reparse_or_symlink(&cache_full) {
        return Err(fail("CONTEXT_CORRUPT: invalid cache_path", 1));
    }

    let raw_bytes =
        std::fs::read(&cache_full).map_err(|_| fail(format!("CONTEXT_MISSING: {cache_rel}"), 1))?;
    let raw_text = std::str::from_utf8(&raw_bytes)
        .map_err(|_| fail("CONTEXT_CORRUPT: invalid utf8 encoding", 1))?;
    if raw_text
        .bytes()
        .any(|b| b != b'\n' && (b < 0x20 || b == 0x7F))
    {
        return Err(fail(
            "CONTEXT_CORRUPT: control character or CRLF in cache",
            1,
        ));
    }

    const ALLOWED_KEYS: &[&str] = &[
        "schema",
        "scope_id",
        "head_sha",
        "anchor_paths",
        "anchor_hash",
        "graph_index_sha",
        "summary_ref",
        "summary_sha256",
        "timestamp_utc",
    ];
    let mut kv: HashMap<&str, &str> = HashMap::new();
    if !raw_text.is_empty() {
        let body_text = raw_text.strip_suffix('\n').unwrap_or(raw_text);
        for raw_line in body_text.split('\n') {
            let Some(eq_idx) = raw_line.find('=') else {
                return Err(fail("CONTEXT_CORRUPT: malformed line", 1));
            };
            if eq_idx < 1 {
                return Err(fail("CONTEXT_CORRUPT: malformed line", 1));
            }
            let k = &raw_line[..eq_idx];
            let v = &raw_line[eq_idx + 1..];
            let Some(&known_k) = ALLOWED_KEYS.iter().find(|&&ak| ak == k) else {
                return Err(fail(format!("CONTEXT_CORRUPT: unknown field '{k}'"), 1));
            };
            if kv.contains_key(known_k) {
                return Err(fail(format!("CONTEXT_CORRUPT: duplicate field '{k}'"), 1));
            }
            if v.is_empty() {
                return Err(fail(format!("CONTEXT_CORRUPT: empty field '{k}'"), 1));
            }
            kv.insert(known_k, v);
        }
    }
    for &req_key in ALLOWED_KEYS {
        if !kv.contains_key(req_key) {
            return Err(fail(
                format!("CONTEXT_CORRUPT: missing field '{req_key}'"),
                1,
            ));
        }
    }

    if kv["schema"] != "b3-context-v1" {
        return Err(fail("CONTEXT_CORRUPT: invalid schema", 1));
    }
    if !is_valid_context_scope_id(kv["scope_id"]) {
        return Err(fail("CONTEXT_CORRUPT: invalid scope_id", 1));
    }
    if !is_hex40(kv["head_sha"]) {
        return Err(fail("CONTEXT_CORRUPT: invalid head_sha", 1));
    }

    let mut rec_anchor_arr = Vec::new();
    let mut rec_anchor_csv = "none".to_string();
    if kv["anchor_paths"] == "none" {
        if kv["anchor_hash"] != "none" {
            return Err(fail("CONTEXT_CORRUPT: invalid anchor_hash", 1));
        }
    } else {
        if !is_hex40(kv["anchor_hash"]) {
            return Err(fail("CONTEXT_CORRUPT: invalid anchor_hash", 1));
        }
        let rec_parsed = split_strict_paths(&repo_root, kv["anchor_paths"], false, true)
            .map_err(|_| fail("CONTEXT_CORRUPT: invalid anchor_paths", 1))?;
        if rec_parsed.is_empty() {
            return Err(fail("CONTEXT_CORRUPT: invalid anchor_paths", 1));
        }
        rec_anchor_arr = rec_parsed;
        rec_anchor_csv = rec_anchor_arr.join(",");
    }

    if kv["graph_index_sha"] != "none" && !is_hex40(kv["graph_index_sha"]) {
        return Err(fail("CONTEXT_CORRUPT: invalid graph_index_sha", 1));
    }
    if kv["anchor_paths"] == "none" && kv["graph_index_sha"] == "none" {
        return Err(fail(
            "CONTEXT_CORRUPT: empty cache (anchor_paths or graph_index_sha required)",
            1,
        ));
    }

    let mut rec_sum_full: Option<PathBuf> = None;
    if kv["summary_ref"] == "none" {
        if kv["summary_sha256"] != "none" {
            return Err(fail("CONTEXT_CORRUPT: invalid summary_sha256", 1));
        }
    } else {
        if kv["summary_sha256"].len() != 64
            || !kv["summary_sha256"]
                .bytes()
                .all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
        {
            return Err(fail("CONTEXT_CORRUPT: invalid summary_sha256", 1));
        }
        let CheckpointFileStatus::Ok { full, .. } =
            check_checkpoint_file_path(&repo_root, kv["summary_ref"])
        else {
            return Err(fail("CONTEXT_CORRUPT: missing or invalid summary_ref", 1));
        };
        rec_sum_full = Some(full);
    }

    if !valid_timestamp_utc(kv["timestamp_utc"]) {
        return Err(fail("CONTEXT_CORRUPT: invalid timestamp_utc", 1));
    }
    if !caller_scope.is_empty() && caller_scope != kv["scope_id"] {
        return Err(fail(
            format!(
                "CONTEXT_MISMATCH: scope_id expected={caller_scope} got={}",
                kv["scope_id"]
            ),
            1,
        ));
    }
    if has_caller_summary && caller_summary_val != kv["summary_ref"] {
        return Err(fail(
            format!(
                "CONTEXT_MISMATCH: summary_ref expected={caller_summary_val} got={}",
                kv["summary_ref"]
            ),
            1,
        ));
    }
    if ignore_overlaps_paths(&ign_arr, &rec_anchor_arr) {
        return Err(fail("CONTEXT_ERROR: invalid ignore path", 1));
    }

    let mut reasons = Vec::new();
    if !merge_base_is_ancestor(&repo_root, kv["head_sha"], &live_head_sha, "CONTEXT_ERROR")
        .unwrap_or(false)
    {
        reasons.push("head_diverged");
    }
    if has_caller_anchor && caller_anchor_csv != rec_anchor_csv {
        reasons.push("anchor_scope_changed");
    }
    if !rec_anchor_arr.is_empty() {
        let live_fp = get_tree_fingerprint(&repo_root, &rec_anchor_arr, &ign_arr, "")?;
        if live_fp.tree_hash != kv["anchor_hash"] {
            reasons.push("anchor_changed");
        }
    }
    if kv["summary_ref"] != "none" {
        let Some(sum_full) = rec_sum_full else {
            return Err(fail("CONTEXT_CORRUPT: missing or invalid summary_ref", 1));
        };
        if !sum_full.is_file() || is_reparse_or_symlink(&sum_full) {
            return Err(fail("CONTEXT_CORRUPT: missing or invalid summary_ref", 1));
        }
        let live_sum_sha = sha256_file_for_context(&sum_full)?;
        if live_sum_sha != kv["summary_sha256"] {
            reasons.push("summary_changed");
        }
    }

    let rec_graph_sha = kv["graph_index_sha"];
    let graph_index_status =
        if rec_graph_sha != "none" || (has_caller_graph && caller_graph_val != "none") {
            let probe_paths = if !scope_arr.is_empty() {
                let mut raw = Vec::new();
                raw.extend(rec_anchor_arr.iter().cloned());
                if has_caller_anchor {
                    raw.extend(caller_anchor_arr.iter().cloned());
                }
                raw.extend(scope_arr);
                sort_ordinal(raw, false)
            } else {
                Vec::new()
            };
            if rec_graph_sha != "none" {
                let graph_mismatch = has_caller_graph && caller_graph_val != rec_graph_sha;
                let rec_fresh = test_graph_index_fresh(
                    &repo_root,
                    rec_graph_sha,
                    &live_head_sha,
                    &probe_paths,
                    &ign_arr,
                )?;
                if graph_mismatch {
                    reasons.push("graph_index_mismatch");
                }
                if !rec_fresh {
                    reasons.push("graph_index_stale");
                }
                if graph_mismatch || !rec_fresh {
                    "STALE"
                } else {
                    "FRESH"
                }
            } else {
                reasons.push("graph_index_mismatch");
                if !test_graph_index_fresh(
                    &repo_root,
                    &caller_graph_val,
                    &live_head_sha,
                    &probe_paths,
                    &ign_arr,
                )? {
                    reasons.push("graph_index_stale");
                }
                "STALE"
            }
        } else {
            "NOT_RECORDED"
        };

    let anchor_status = if kv["anchor_paths"] == "none" {
        "NOT_RECORDED"
    } else if reasons.iter().any(|&r| {
        matches!(
            r,
            "head_diverged" | "anchor_scope_changed" | "anchor_changed"
        )
    }) {
        "STALE"
    } else {
        "FRESH"
    };

    if !reasons.is_empty() {
        let reason_csv = reasons.join(",");
        return Ok((
            format!(
                "CONTEXT_STALE: scope={} reasons={reason_csv} anchor_status={anchor_status} graph_index={graph_index_status} live_lsp_eligible=true",
                kv["scope_id"]
            ),
            2,
        ));
    }

    Ok((
        format!(
            "CONTEXT_FRESH: scope={} head={live_head_sha} anchor_status={anchor_status} graph_index={graph_index_status} live_lsp_eligible=true",
            kv["scope_id"]
        ),
        0,
    ))
}
