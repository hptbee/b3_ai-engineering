use std::collections::{HashMap, HashSet};
use std::path::Path;

use crate::config::{resolve_config, ReviewSizingConfig};
use crate::error::{fail, B3Error};
use crate::fs::{
    normalize_path_value, normalize_repo_root, sort_ordinal, split_path_csv_checked,
    test_binary_file, test_checkpoint_path, test_code_path, test_noise_file, test_path_match,
    test_secret_path, test_test_path,
};
use crate::git::{
    assert_valid_git_rev, git_err_detail, new_working_tree_oid, resolve_scope_target_and_base,
    run_git, run_git_paths_z, GitZMode,
};

pub(crate) fn normalize_size_class(raw: &str) -> Option<&'static str> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    match trimmed.to_ascii_uppercase().as_str() {
        "SMALL" | "S" => Some("S"),
        "MEDIUM" | "M" => Some("M"),
        "LARGE" | "L" => Some("L"),
        "VERY_LARGE" | "XL" => Some("XL"),
        "XS" => Some("XS"),
        "XXL" => Some("XXL"),
        "NOISE_ONLY" => Some("NOISE_ONLY"),
        "CLEAN_AFTER_FIX" => Some("CLEAN_AFTER_FIX"),
        _ => None,
    }
}

pub fn get_tshirt_size_with_thresholds(
    files_count: usize,
    lines_count: usize,
    sizing: &ReviewSizingConfig,
) -> &'static str {
    if files_count == 0 {
        return "NOISE_ONLY";
    }
    if files_count <= sizing.xs_max_files && lines_count <= sizing.xs_max_loc {
        return "XS";
    }
    if files_count <= sizing.s_max_files && lines_count <= sizing.s_max_loc {
        return "S";
    }
    if files_count <= sizing.m_max_files && lines_count <= sizing.m_max_loc {
        return "M";
    }
    if sizing == &ReviewSizingConfig::default() {
        // Preserve exact existing strict boundary (< 50 files && < 2000 LOC) at default thresholds.
        if files_count < 50 && lines_count < 2000 {
            return "L";
        }
    } else if files_count <= sizing.l_max_files && lines_count <= sizing.l_max_loc {
        return "L";
    }
    if files_count <= sizing.xl_max_files && lines_count <= sizing.xl_max_loc {
        return "XL";
    }
    "XXL"
}

pub fn get_tshirt_size(files_count: usize, lines_count: usize) -> &'static str {
    get_tshirt_size_with_thresholds(files_count, lines_count, &ReviewSizingConfig::default())
}

pub fn test_doc_or_asset_path(path_val: &str) -> bool {
    let low = path_val.to_ascii_lowercase();
    let has_eval_dir = low == "evals" || low.starts_with("evals/") || low.contains("/evals/");
    if has_eval_dir && (low.ends_with(".yml") || low.ends_with(".yaml")) {
        return true;
    }
    matches!(
        Path::new(&low).extension().and_then(|e| e.to_str()),
        Some(
            "md" | "mdx"
                | "txt"
                | "rst"
                | "adoc"
                | "png"
                | "jpg"
                | "jpeg"
                | "gif"
                | "svg"
                | "ico"
                | "woff"
                | "woff2"
                | "ttf"
                | "eot"
                | "pdf"
        )
    )
}

pub fn test_generated_code_path(path_val: &str) -> bool {
    let low = path_val.to_ascii_lowercase();
    if low.contains(".generated.") || low.contains(".pb.") {
        return true;
    }
    if low.split('/').any(|seg| seg == "generated" || seg == "gen") {
        return true;
    }
    low.ends_with(".g.cs") || low.ends_with(".designer.cs")
}

pub fn test_contract_path(path_val: &str) -> bool {
    let low = path_val.to_ascii_lowercase();
    if test_doc_or_asset_path(&low) || test_test_path(&low) || test_noise_file(&low) {
        return false;
    }
    if matches!(
        Path::new(&low).extension().and_then(|e| e.to_str()),
        Some("proto" | "graphql" | "gql" | "sql" | "csproj" | "sln")
    ) {
        return true;
    }
    let leaf = low.rsplit('/').next().unwrap_or("");
    if matches!(
        leaf,
        "package.json" | "pnpm-workspace.yaml" | "go.mod" | "cargo.toml" | "pyproject.toml"
    ) {
        return true;
    }
    has_segment_or_prefix(
        &low,
        &[
            "openapi",
            "swagger",
            "proto",
            "graphql",
            "contract",
            "contracts",
            "schema",
            "schemas",
            "interface",
            "interfaces",
            "shared-types",
            "api-types",
        ],
        true,
    )
}

fn has_segment_or_prefix(low: &str, keys: &[&str], match_dot_after: bool) -> bool {
    for seg in low.split('/') {
        if keys.contains(&seg) {
            return true;
        }
        if match_dot_after {
            if let Some(stem) = seg.split('.').next() {
                if keys.contains(&stem) {
                    return true;
                }
            }
        }
    }
    false
}

fn has_dir_or_leaf_prefix(low: &str, keys: &[&str]) -> bool {
    let mut parts = low.split('/').peekable();
    while let Some(seg) = parts.next() {
        if keys.contains(&seg) {
            return true;
        }
        if parts.peek().is_none() {
            if let Some(dot_idx) = seg.find('.') {
                let prefix = &seg[..dot_idx];
                // Matches `[^/]*\.` in `b3 guard` for auth_security keywords.
                if keys.iter().any(|k| prefix.starts_with(k)) {
                    return true;
                }
            }
        }
    }
    false
}

pub fn get_raw_module_group(path_val: &str) -> String {
    let mut parts = path_val.split('/');
    match (parts.next(), parts.next(), parts.next()) {
        (Some(p0), Some(p1), Some(_)) => format!("{p0}/{p1}"),
        (Some(p0), Some(_), None) => p0.to_string(),
        _ => "root".to_string(),
    }
}

fn add_signal_tag(map: &mut HashMap<String, Vec<String>>, key: &str, tag: &str) {
    let list = map.entry(key.to_string()).or_default();
    if !list.iter().any(|x| x == tag) {
        list.push(tag.to_string());
    }
}

pub fn scan_path_risk_signals(map: &mut HashMap<String, Vec<String>>, path_val: &str) {
    let low = path_val.to_ascii_lowercase();
    if test_generated_code_path(&low) {
        add_signal_tag(map, path_val, "generated_code");
    }
    if test_doc_or_asset_path(&low) || test_test_path(&low) {
        return;
    }
    if test_secret_path(&low)
        || has_dir_or_leaf_prefix(
            &low,
            &[
                "auth",
                "authn",
                "authz",
                "oauth",
                "oidc",
                "jwt",
                "rbac",
                "acl",
                "session",
                "sessions",
                "security",
                "crypto",
                "cipher",
                "secret",
                "secrets",
                "token",
                "tokens",
                "credential",
                "credentials",
                "permission",
                "permissions",
                "policy",
                "policies",
            ],
        )
    {
        add_signal_tag(map, path_val, "auth_security");
    }
    let leaf = low.rsplit('/').next().unwrap_or("");
    if ((leaf.starts_with("b3-guard.") || leaf.starts_with("install") || leaf.starts_with("sync"))
        && (leaf.ends_with(".ps1") || leaf.ends_with(".sh")))
        || low.starts_with("src/guard/")
        || low.starts_with("src/adapters/")
        || low.starts_with("src/pr/")
        || low == "src/fs.rs"
        || low == "src/git.rs"
        || low == "src/process.rs"
        || low.starts_with("scripts/bootstrap-b3.")
    {
        add_signal_tag(map, path_val, "fs_git_security");
    }
    if low.ends_with(".sql")
        || has_segment_or_prefix(
            &low,
            &[
                "migration",
                "migrations",
                "schema",
                "prisma",
                "alembic",
                "flyway",
                "liquibase",
                "db",
                "database",
                "persistence",
                "repositories",
                "efcore",
            ],
            false,
        )
    {
        add_signal_tag(map, path_val, "db_migration_tx");
    }
    if low.ends_with(".proto")
        || low.ends_with(".graphql")
        || low.ends_with(".gql")
        || has_segment_or_prefix(
            &low,
            &[
                "openapi",
                "swagger",
                "proto",
                "graphql",
                "contract",
                "contracts",
                "api",
                "route",
                "routes",
                "controller",
                "controllers",
                "endpoint",
                "endpoints",
                "schema",
                "schemas",
                "interface",
                "interfaces",
                "public",
            ],
            false,
        )
        || leaf.starts_with("contract.")
        || leaf.starts_with("contracts.")
        || leaf.starts_with("shared-types.")
        || leaf.starts_with("api-types.")
    {
        add_signal_tag(map, path_val, "public_api_contract");
    }
    if has_segment_or_prefix(
        &low,
        &[
            "cache",
            "redis",
            "queue",
            "worker",
            "lock",
            "mutex",
            "concurrency",
            "scheduler",
            "state",
            "store",
        ],
        false,
    ) {
        add_signal_tag(map, path_val, "concurrency_state_cache");
    }
    if has_segment_or_prefix(
        &low,
        &[
            "render",
            "renderer",
            "shader",
            "three",
            "canvas",
            "scene",
            "webgl",
            "engine",
            "query",
            "queries",
            "indexer",
            "serializer",
            "stream",
        ],
        false,
    ) {
        add_signal_tag(map, path_val, "perf_hot_path");
    }
}

fn contains_word_token(line_lower: &str, tokens: &[&str]) -> bool {
    let bytes = line_lower.as_bytes();
    for tok in tokens {
        let tb = tok.as_bytes();
        let mut start = 0;
        while let Some(pos) = line_lower[start..].find(tok) {
            let abs = start + pos;
            let left_ok =
                abs == 0 || !(bytes[abs - 1].is_ascii_alphanumeric() || bytes[abs - 1] == b'_');
            if left_ok {
                let _end = abs + tb.len();
                return true;
            }
            start = abs + 1;
        }
    }
    false
}

/// Detects destructive SQL statements (`DROP TABLE`, `DROP DATABASE`, `TRUNCATE TABLE`)
/// with word-boundary accuracy.
pub(crate) fn find_destructive_sql(line: &str) -> Option<&'static str> {
    let low = line.to_ascii_lowercase();
    find_destructive_sql_lower(&low)
}

fn find_destructive_sql_lower(low: &str) -> Option<&'static str> {
    let bytes = low.as_bytes();
    let is_w = |b: u8| b.is_ascii_alphanumeric() || b == b'_';
    for (first, second, tag) in [
        ("drop", "table", "drop table"),
        ("drop", "database", "drop database"),
        ("truncate", "table", "truncate table"),
    ] {
        let mut start = 0;
        while let Some(pos) = low[start..].find(first) {
            let abs = start + pos;
            let left_ok = abs == 0 || !is_w(bytes[abs - 1]);
            if left_ok {
                let mut j = abs + first.len();
                let mut ws = 0;
                while j < bytes.len() && bytes[j].is_ascii_whitespace() {
                    ws += 1;
                    j += 1;
                }
                if ws > 0 && low[j..].starts_with(second) {
                    let end = j + second.len();
                    if end == bytes.len() || !is_w(bytes[end]) {
                        return Some(tag);
                    }
                }
            }
            start = abs + 1;
        }
    }
    None
}

fn contains_two_word_sql(
    line_lower: &str,
    first: &str,
    second: &str,
    require_end_boundary: bool,
) -> bool {
    let bytes = line_lower.as_bytes();
    let mut start = 0;
    while let Some(pos) = line_lower[start..].find(first) {
        let abs = start + pos;
        let left_ok =
            abs == 0 || !(bytes[abs - 1].is_ascii_alphanumeric() || bytes[abs - 1] == b'_');
        if left_ok {
            let mut j = abs + first.len();
            let mut ws_cnt = 0;
            while j < bytes.len() && matches!(bytes[j], b' ' | b'\t') {
                ws_cnt += 1;
                j += 1;
            }
            if ws_cnt > 0 && line_lower[j..].starts_with(second) {
                let end = j + second.len();
                if !require_end_boundary
                    || end == bytes.len()
                    || !(bytes[end].is_ascii_alphanumeric() || bytes[end] == b'_')
                {
                    return true;
                }
            }
        }
        start = abs + 1;
    }
    false
}

fn scan_line_risk_signals(
    map: &mut HashMap<String, Vec<String>>,
    path_val: &str,
    line_lower: &str,
) {
    let has_reject_unauth_false = line_lower.find("rejectunauthorized").is_some_and(|pos| {
        let after = line_lower[pos + "rejectunauthorized".len()..].trim_start_matches([' ', '\t']);
        after
            .strip_prefix(':')
            .is_some_and(|rest| rest.trim_start_matches([' ', '\t']).starts_with("false"))
    });
    if [
        "verifytoken",
        "jwt.",
        "bcrypt",
        "argon2",
        "pbkdf2",
        "crypto.",
        "[authorize",
        "allowanonymous",
        "eval(",
        "execsync",
        "child_process",
        "dangerouslysetinnerhtml",
    ]
    .iter()
    .any(|pat| line_lower.contains(pat))
        || has_reject_unauth_false
        || contains_two_word_sql(line_lower, "chmod", "777", false)
    {
        add_signal_tag(map, path_val, "auth_security");
    }

    let has_rm_rf = contains_two_word_sql(line_lower, "rm", "-rf", false);
    let has_remove_item_recurse = line_lower
        .find("remove-item")
        .is_some_and(|pos| line_lower[pos..].contains("-recurse"));
    let has_git_push = contains_two_word_sql(line_lower, "git", "push", false);
    let has_git_reset_hard = line_lower
        .find("git")
        .is_some_and(|pos| contains_two_word_sql(&line_lower[pos..], "reset", "--hard", false));
    if line_lower.contains("git_index_file")
        || line_lower.contains("reparsepoint")
        || line_lower.contains("symboliclink")
        || line_lower.contains("junction")
        || has_rm_rf
        || has_remove_item_recurse
        || has_git_push
        || has_git_reset_hard
    {
        add_signal_tag(map, path_val, "fs_git_security");
    }

    let is_destructive = find_destructive_sql_lower(line_lower).is_some();
    let is_db_tx = is_destructive
        || contains_two_word_sql(line_lower, "alter", "table", false)
        || contains_two_word_sql(line_lower, "begin", "transaction", false)
        || contains_word_token(line_lower, &["isolationlevel", "savechanges", "migrate("]);
    if is_db_tx {
        add_signal_tag(map, path_val, "db_migration_tx");
        if is_destructive {
            add_signal_tag(map, path_val, "_db_destructive");
        }
    }

    if contains_word_token(
        line_lower,
        &[
            "mutex",
            "semaphore",
            "concurrentdictionary",
            "channel<",
            "promise.all",
            "abortcontroller",
            "imemorycache",
            "distributedcache",
        ],
    ) {
        add_signal_tag(map, path_val, "concurrency_state_cache");
    }

    if contains_word_token(
        line_lower,
        &[
            "useframe",
            "requestanimationframe",
            "instancedmesh",
            "webglrenderer",
            "asnotracking",
        ],
    ) {
        add_signal_tag(map, path_val, "perf_hot_path");
    }

    if contains_word_token(line_lower, &["json.stringify", "json.parse"]) {
        add_signal_tag(map, path_val, "_json_serde");
    }
    let has_loop_or_stream = contains_word_token(
        line_lower,
        &[
            "foreach",
            "readline",
            "createreadstream",
            "createwritestream",
            "readable",
            "writable",
            "transform",
            "stream",
            "buffer",
            "uint8array",
            "arraybuffer",
            "chunk",
            "ndjson",
            "jsonl",
            "batch",
            "bulk",
            "maxbuffer",
        ],
    ) || line_lower.contains(".map(")
        || line_lower.contains(".flatmap(")
        || line_lower.contains(".reduce(")
        || line_lower.find("for").is_some_and(|p| {
            (p == 0 || !line_lower.as_bytes()[p - 1].is_ascii_alphanumeric())
                && line_lower[p + 3..]
                    .trim_start_matches([' ', '\t'])
                    .starts_with('(')
        })
        || line_lower.find("while").is_some_and(|p| {
            (p == 0 || !line_lower.as_bytes()[p - 1].is_ascii_alphanumeric())
                && line_lower[p + 5..]
                    .trim_start_matches([' ', '\t'])
                    .starts_with('(')
        })
        || line_lower.find("1024").is_some_and(|p| {
            (p == 0 || !line_lower.as_bytes()[p - 1].is_ascii_alphanumeric())
                && line_lower[p + 4..]
                    .trim_start_matches([' ', '\t'])
                    .starts_with('*')
        });
    if has_loop_or_stream {
        add_signal_tag(map, path_val, "_serde_hot_ctx");
    }
    if map.get(path_val).is_some_and(|tags| {
        tags.iter().any(|t| t == "_json_serde") && tags.iter().any(|t| t == "_serde_hot_ctx")
    }) {
        add_signal_tag(map, path_val, "perf_hot_path");
    }
}

#[derive(Debug, Clone)]
pub struct ScopeData {
    pub review_files: Vec<String>,
    pub noise_files: Vec<String>,
    pub file_lines: HashMap<String, usize>,
    pub file_signals: HashMap<String, Vec<String>>,
    pub total_lines: usize,
    pub change_types: String,
    pub untracked_set: HashSet<String>,
}

/// Collects diff/untracked scope data, line counts, noise split, and risk signals.
pub fn collect_scope_data(
    root: &Path,
    resolved_base: &str,
    target_commit_sha: &str,
    ign_paths: &[String],
    fail_prefix: &str,
) -> Result<ScopeData, B3Error> {
    let no_env: [(&str, &str); 0] = [];
    let ns_args: Vec<&str> = if !target_commit_sha.is_empty() {
        vec![
            "diff",
            "--no-ext-diff",
            "--no-renames",
            "--numstat",
            "-z",
            resolved_base,
            target_commit_sha,
            "--",
        ]
    } else {
        vec![
            "diff",
            "--no-ext-diff",
            "--no-renames",
            "--numstat",
            "-z",
            resolved_base,
            "--",
        ]
    };
    let ns_res = run_git(root, &ns_args, &no_env, None)?;
    if ns_res.exit_code != 0 {
        return Err(fail(
            format!(
                "{fail_prefix}: git diff --numstat failed: {}",
                git_err_detail(&ns_res)
            ),
            1,
        ));
    }

    let st_args: Vec<&str> = if !target_commit_sha.is_empty() {
        vec![
            "diff",
            "--no-ext-diff",
            "--no-renames",
            "--name-status",
            "-z",
            resolved_base,
            target_commit_sha,
            "--",
        ]
    } else {
        vec![
            "diff",
            "--no-ext-diff",
            "--no-renames",
            "--name-status",
            "-z",
            resolved_base,
            "--",
        ]
    };
    let st_res = run_git(root, &st_args, &no_env, None)?;
    if st_res.exit_code != 0 {
        return Err(fail(
            format!(
                "{fail_prefix}: git diff --name-status failed: {}",
                git_err_detail(&st_res)
            ),
            1,
        ));
    }

    let untracked = if !target_commit_sha.is_empty() {
        Vec::new()
    } else {
        run_git_paths_z(
            root,
            &["ls-files", "--others", "--exclude-standard", "-z"],
            GitZMode::Names,
            "GIT_ERROR",
            &no_env,
        )?
    };

    // Parse `--name-status -z`: status\0path\0
    let mut st_toks: Vec<&[u8]> = st_res.stdout.split(|&b| b == 0).collect();
    if matches!(st_toks.last(), Some(l) if l.is_empty()) {
        st_toks.pop();
    }
    let est = (st_toks.len() / 2 + untracked.len()).max(16);
    let mut review_files = Vec::with_capacity(est);
    let mut review_seen: HashSet<String> = HashSet::with_capacity(est);
    let mut noise_files = Vec::new();
    let mut noise_seen: HashSet<String> = HashSet::new();
    let mut file_lines: HashMap<String, usize> = HashMap::with_capacity(est);
    let mut file_signals: HashMap<String, Vec<String>> = HashMap::with_capacity(est / 4 + 8);
    let mut change_map: HashMap<String, char> = HashMap::with_capacity(est);
    let mut untracked_set: HashSet<String> = HashSet::with_capacity(untracked.len());
    let mut scan_content_set: HashSet<String> = HashSet::new();
    let mut total_lines = 0usize;

    let mut si = 0;
    while si + 1 < st_toks.len() {
        let st = String::from_utf8_lossy(st_toks[si]);
        let path_raw = String::from_utf8_lossy(st_toks[si + 1]);
        si += 2;
        let ch = match st.chars().next().map(|c| c.to_ascii_uppercase()) {
            Some('A') => 'A',
            Some('D') => 'D',
            _ => 'M',
        };
        let fp = normalize_path_value(&path_raw);
        if !fp.is_empty()
            && !test_checkpoint_path(&fp)
            && (ign_paths.is_empty() || !test_path_match(&fp, ign_paths))
        {
            change_map.insert(fp, ch);
        }
    }

    // Parse `--numstat -z`: "<added>\t<deleted>\t<path>\0"
    for rec in ns_res.stdout.split(|&b| b == 0) {
        if rec.is_empty() {
            continue;
        }
        let line_str = String::from_utf8_lossy(rec);
        let mut cols = line_str.splitn(3, '\t');
        let (Some(added_s), Some(deleted_s), Some(raw_path)) =
            (cols.next(), cols.next(), cols.next())
        else {
            continue;
        };
        let p = normalize_path_value(raw_path);
        if p.is_empty()
            || test_checkpoint_path(&p)
            || (!ign_paths.is_empty() && test_path_match(&p, ign_paths))
        {
            continue;
        }
        scan_path_risk_signals(&mut file_signals, &p);
        if test_noise_file(&p) {
            if noise_seen.insert(p.clone()) {
                noise_files.push(p);
            }
            continue;
        }
        if review_seen.insert(p.clone()) {
            review_files.push(p.clone());
        }
        let mut flc = 0usize;
        if let Ok(a) = added_s.trim().parse::<usize>() {
            flc += a;
        }
        if let Ok(d) = deleted_s.trim().parse::<usize>() {
            flc += d;
        }
        file_lines.insert(p.clone(), flc);
        total_lines += flc;
        if !(test_doc_or_asset_path(&p) || test_test_path(&p)) {
            scan_content_set.insert(p);
        }
    }

    for u in untracked {
        if u.is_empty()
            || test_checkpoint_path(&u)
            || (!ign_paths.is_empty() && test_path_match(&u, ign_paths))
        {
            continue;
        }
        scan_path_risk_signals(&mut file_signals, &u);
        if test_noise_file(&u) {
            if noise_seen.insert(u.clone()) {
                noise_files.push(u);
            }
            continue;
        }
        if review_seen.insert(u.clone()) {
            review_files.push(u.clone());
            untracked_set.insert(u.clone());
            change_map.insert(u.clone(), 'U');
            let full = root.join(u.replace('/', std::path::MAIN_SEPARATOR_STR));
            let mut flc = 0usize;
            if full.is_file() && !test_binary_file(&full) {
                let is_text_code = !(test_doc_or_asset_path(&u) || test_test_path(&u));
                if let Ok(content) = std::fs::read_to_string(&full) {
                    let lines_arr: Vec<&str> = content.lines().collect();
                    flc = lines_arr.len();
                    if is_text_code {
                        for uln in lines_arr {
                            scan_line_risk_signals(
                                &mut file_signals,
                                &u,
                                &uln.to_ascii_lowercase(),
                            );
                        }
                    }
                }
            }
            file_lines.insert(u, flc);
            total_lines += flc;
        }
    }

    if !scan_content_set.is_empty() {
        let d_args: Vec<&str> = if !target_commit_sha.is_empty() {
            vec![
                "diff",
                "--no-ext-diff",
                "--no-renames",
                "-U0",
                resolved_base,
                target_commit_sha,
                "--",
            ]
        } else {
            vec![
                "diff",
                "--no-ext-diff",
                "--no-renames",
                "-U0",
                resolved_base,
                "--",
            ]
        };
        let d_res = run_git(root, &d_args, &no_env, None)?;
        if d_res.exit_code != 0 {
            return Err(fail(
                format!(
                    "{fail_prefix}: git diff -U0 failed: {}",
                    git_err_detail(&d_res)
                ),
                1,
            ));
        }
        if !d_res.stdout.is_empty() {
            let mut hdr_old_path = String::new();
            let mut cur_path = String::new();
            let mut cur_scan = false;
            let mut in_hunk = false;
            for dl in String::from_utf8_lossy(&d_res.stdout).lines() {
                if dl.starts_with("diff --git ") {
                    hdr_old_path.clear();
                    cur_path.clear();
                    cur_scan = false;
                    in_hunk = false;
                    continue;
                }
                if !in_hunk {
                    if let Some(rest) = dl.strip_prefix("--- ") {
                        hdr_old_path = if dl != "--- /dev/null" {
                            normalize_path_value(rest.strip_prefix("a/").unwrap_or(rest))
                        } else {
                            String::new()
                        };
                        continue;
                    }
                    if let Some(rest) = dl.strip_prefix("+++ ") {
                        cur_path = if dl != "+++ /dev/null" {
                            normalize_path_value(rest.strip_prefix("b/").unwrap_or(rest))
                        } else {
                            hdr_old_path.clone()
                        };
                        cur_scan = !cur_path.is_empty() && scan_content_set.contains(&cur_path);
                        continue;
                    }
                    if dl.starts_with("@@ ") {
                        in_hunk = true;
                        continue;
                    }
                    continue;
                }
                if dl.starts_with("@@ ") {
                    continue;
                }
                if cur_scan && !cur_path.is_empty() && (dl.starts_with('+') || dl.starts_with('-'))
                {
                    scan_line_risk_signals(
                        &mut file_signals,
                        &cur_path,
                        &dl[1..].to_ascii_lowercase(),
                    );
                }
            }
        }
    }

    let (mut cnt_a, mut cnt_m, mut cnt_d, mut cnt_u) = (0usize, 0usize, 0usize, 0usize);
    for rf in &review_files {
        match change_map.get(rf).copied().unwrap_or('M') {
            'A' => cnt_a += 1,
            'D' => cnt_d += 1,
            'U' => cnt_u += 1,
            _ => cnt_m += 1,
        }
    }

    Ok(ScopeData {
        review_files: sort_ordinal(review_files, false),
        noise_files: sort_ordinal(noise_files, false),
        file_lines,
        file_signals,
        total_lines,
        change_types: format!("A:{cnt_a},M:{cnt_m},D:{cnt_d},U:{cnt_u}"),
        untracked_set,
    })
}

pub struct RiskResult {
    pub risk_level: &'static str,
    pub risk_signals: String,
    pub recommended_specialists: String,
}

pub fn eval_risk_for_subset(
    paths_list: &[String],
    file_signals_map: Option<&HashMap<String, Vec<String>>>,
    file_lines_map: Option<&HashMap<String, usize>>,
) -> RiskResult {
    let mut sigs = Vec::new();
    let mut has_destructive = false;
    let mut code_groups = HashSet::new();
    let mut has_contract_sig = false;
    let mut code_file_cnt = 0usize;
    let mut code_line_cnt = 0usize;

    let mut push_sig = |s: &str| {
        if s == "_db_destructive" {
            has_destructive = true;
            return;
        }
        if s.starts_with('_') {
            return;
        }
        if !sigs.iter().any(|x| x == s) {
            sigs.push(s.to_string());
        }
        if s == "public_api_contract" || s == "db_migration_tx" {
            has_contract_sig = true;
        }
    };

    for p in paths_list {
        if p.is_empty() {
            continue;
        }
        if let Some(tags) = file_signals_map.and_then(|m| m.get(p)) {
            for s in tags {
                push_sig(s);
            }
        } else {
            let mut tmp_map = HashMap::new();
            scan_path_risk_signals(&mut tmp_map, p);
            if let Some(tags) = tmp_map.get(p) {
                for s in tags {
                    push_sig(s);
                }
            }
        }
        if !(test_doc_or_asset_path(p)
            || test_test_path(p)
            || test_generated_code_path(p)
            || test_noise_file(p))
        {
            code_groups.insert(get_raw_module_group(p));
            if test_code_path(p) || test_contract_path(p) {
                code_file_cnt += 1;
                if let Some(&lc) = file_lines_map.and_then(|m| m.get(p)) {
                    code_line_cnt += lc;
                }
            }
        }
    }

    let mut cross_high = false;
    if code_groups.len() >= 4 && has_contract_sig {
        if !sigs.iter().any(|s| s == "cross_module_blast") {
            sigs.push("cross_module_blast".to_string());
        }
        cross_high = true;
    } else if code_groups.len() >= 3 && !sigs.iter().any(|s| s == "cross_module_blast") {
        sigs.push("cross_module_blast".to_string());
    }

    let mut max_sev = 1u8;
    let mut specs = Vec::new();
    let mut push_spec = |sp: &str| {
        if !specs.iter().any(|x| x == sp) {
            specs.push(sp.to_string());
        }
    };
    for s in &sigs {
        match s.as_str() {
            "auth_security" | "fs_git_security" => {
                max_sev = max_sev.max(4);
                push_spec("b3-security-reviewer");
            }
            "db_migration_tx" => {
                let db_sev = if has_destructive { 4 } else { 3 };
                max_sev = max_sev.max(db_sev);
                push_spec("b3-architecture-reviewer");
                if has_destructive {
                    push_spec("b3-security-reviewer");
                }
            }
            "public_api_contract" => {
                max_sev = max_sev.max(3);
                push_spec("b3-architecture-reviewer");
            }
            "concurrency_state_cache" => {
                max_sev = max_sev.max(3);
                push_spec("b3-architecture-reviewer");
                push_spec("b3-performance-reviewer");
            }
            "perf_hot_path" => {
                max_sev = max_sev.max(3);
                push_spec("b3-performance-reviewer");
            }
            "generated_code" => {
                max_sev = max_sev.max(2);
            }
            "cross_module_blast" => {
                let c_sev = if cross_high { 3 } else { 2 };
                max_sev = max_sev.max(c_sev);
                if cross_high {
                    push_spec("b3-architecture-reviewer");
                }
            }
            _ => {}
        }
    }

    if max_sev < 2 && (code_file_cnt > 1 || code_line_cnt > 100) {
        if !sigs.iter().any(|s| s == "general_code_change") {
            sigs.push("general_code_change".to_string());
        }
        max_sev = 2;
    }

    let risk_level = match max_sev {
        4 => "CRITICAL",
        3 => "HIGH",
        2 => "MEDIUM",
        _ => "LOW",
    };
    let sig_out = if sigs.is_empty() {
        "none".to_string()
    } else {
        sort_ordinal(sigs, false).join(",")
    };
    let spec_out = if specs.is_empty() {
        "none".to_string()
    } else {
        sort_ordinal(specs, false).join(",")
    };

    RiskResult {
        risk_level,
        risk_signals: sig_out,
        recommended_specialists: spec_out,
    }
}

/// Executes `b3 guard diff-scope`.
pub fn run_diff_scope(
    repo_root_raw: &str,
    base_sha_raw: &str,
    prev_sha_raw: &str,
    target_ref_raw: &str,
    ignore_dirty_paths: &str,
) -> Result<(String, i32), B3Error> {
    let ignored = split_path_csv_checked(ignore_dirty_paths, "DIFF_SCOPE_FAIL", true, None)?;
    let repo_root = normalize_repo_root(repo_root_raw)?;
    let scope = resolve_scope_target_and_base(
        &repo_root,
        target_ref_raw,
        base_sha_raw,
        &ignored,
        "DIFF_SCOPE_FAIL",
        "object",
    )?;
    let target_trim = scope.target_ref;
    let target_commit_sha = scope.target_commit_sha;
    let resolved_base = scope.base_sha;

    let scope_data = collect_scope_data(
        &repo_root,
        &resolved_base,
        &target_commit_sha,
        &ignored,
        "DIFF_SCOPE_FAIL",
    )?;
    let review_files = scope_data.review_files;
    let noise_files = scope_data.noise_files;
    let total_lines = scope_data.total_lines;

    let no_env: [(&str, &str); 0] = [];
    let mut df_out: Option<String> = None;
    let mut delta_arr = Vec::new();
    let prev_trim = prev_sha_raw.trim();
    if !prev_trim.is_empty() {
        assert_valid_git_rev(
            &repo_root,
            prev_trim,
            "commit",
            "DIFF_SCOPE_FAIL",
            "--prev-sha",
        )?;
        let delta_end = if !target_trim.is_empty() {
            target_commit_sha.clone()
        } else {
            new_working_tree_oid(&repo_root, "DIFF_SCOPE_FAIL", false)?
        };
        let delta_paths = run_git_paths_z(
            &repo_root,
            &[
                "diff",
                "--no-ext-diff",
                "--no-renames",
                "--name-only",
                "-z",
                prev_trim,
                &delta_end,
                "--",
            ],
            GitZMode::Names,
            "DIFF_SCOPE_FAIL",
            &no_env,
        )?;
        let filtered_delta = delta_paths.into_iter().filter(|dp| {
            !dp.is_empty()
                && !test_checkpoint_path(dp)
                && (ignored.is_empty() || !test_path_match(dp, &ignored))
                && !test_noise_file(dp)
        });
        delta_arr = sort_ordinal(filtered_delta, false);
        df_out = Some(if delta_arr.is_empty() {
            "none".to_string()
        } else {
            delta_arr.join(",")
        });
    }

    if review_files.is_empty() && noise_files.is_empty() {
        match &df_out {
            None => return Err(fail("EMPTY_DIFF", 2)),
            Some(df) if df == "none" => return Err(fail("EMPTY_DIFF", 2)),
            Some(df) => {
                let clean_risk = eval_risk_for_subset(&delta_arr, None, None);
                let out = format!(
                    "size_class=CLEAN_AFTER_FIX\nfiles=0\nlines=0\nreview_files=none\nnoise_files=none\ndelta_files={df}\nrisk_level={}\nrisk_signals={}\nrecommended_specialists={}",
                    clean_risk.risk_level,
                    clean_risk.risk_signals,
                    clean_risk.recommended_specialists
                );
                return Ok((out, 0));
            }
        }
    }

    let cfg = resolve_config(Some(&repo_root), None, &[]).config;
    let file_count = review_files.len();
    let size_class = get_tshirt_size_with_thresholds(file_count, total_lines, &cfg.review.sizing);
    let risk_target = if !review_files.is_empty() {
        &review_files
    } else {
        &noise_files
    };
    let risk_res = eval_risk_for_subset(
        risk_target,
        Some(&scope_data.file_signals),
        Some(&scope_data.file_lines),
    );

    let rf_out = if review_files.is_empty() {
        "none".to_string()
    } else {
        review_files.join(",")
    };
    let nf_out = if noise_files.is_empty() {
        "none".to_string()
    } else {
        noise_files.join(",")
    };

    let mut lines = vec![
        format!("size_class={size_class}"),
        format!("files={file_count}"),
        format!("lines={total_lines}"),
        format!("review_files={rf_out}"),
        format!("noise_files={nf_out}"),
    ];
    if let Some(df) = df_out {
        lines.push(format!("delta_files={df}"));
    }
    lines.push(format!("risk_level={}", risk_res.risk_level));
    lines.push(format!("risk_signals={}", risk_res.risk_signals));
    lines.push(format!(
        "recommended_specialists={}",
        risk_res.recommended_specialists
    ));
    Ok((lines.join("\n"), 0))
}
