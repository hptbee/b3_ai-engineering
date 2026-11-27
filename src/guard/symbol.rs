use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::Path;

use crate::error::{fail, B3Error};
use crate::fs::{
    normalize_path_value, normalize_repo_root, sort_ordinal, split_path_csv_checked,
    test_checkpoint_path, test_code_path, test_noise_file, test_path_match, test_test_path,
};
use crate::git::{
    git_err_detail, resolve_scope_target_and_base, run_git, run_git_paths_z, GitZMode,
};

const SKIP_SYMBOL_NAMES: &[&str] = &[
    "main",
    "init",
    "constructor",
    "render",
    "setup",
    "teardown",
    "default",
    "handler",
    "index",
    "test",
    "describe",
];

struct SymbolDecl {
    name: String,
    exported: bool,
}

fn trim_leading_ws(s: &str) -> &str {
    s.trim_start_matches([' ', '\t'])
}

fn consume_ident_min3(s: &str, allow_hyphen: bool) -> Option<(&str, &str)> {
    let bytes = s.as_bytes();
    if bytes.is_empty() || !(bytes[0].is_ascii_alphabetic() || bytes[0] == b'_') {
        return None;
    }
    let mut len = 1;
    while len < bytes.len() {
        let b = bytes[len];
        if b.is_ascii_alphanumeric() || b == b'_' || (allow_hyphen && b == b'-') {
            len += 1;
        } else {
            break;
        }
    }
    if len < 3 {
        None
    } else {
        Some((&s[..len], &s[len..]))
    }
}

fn strip_kw<'a>(s: &'a str, kw: &str) -> Option<&'a str> {
    let rest = s.strip_prefix(kw)?;
    if rest.starts_with([' ', '\t']) {
        Some(trim_leading_ws(rest))
    } else {
        None
    }
}

fn extract_symbol_decl(file_path: &str, line_body: &str) -> Option<SymbolDecl> {
    let lower = file_path.to_ascii_lowercase();
    let ext = Path::new(&lower).extension()?.to_str()?;

    let mut sym_name: Option<&str> = None;
    let mut is_exp = false;

    match ext {
        "js" | "jsx" | "ts" | "tsx" | "mjs" | "cjs" => {
            let mut cur = trim_leading_ws(line_body);
            if let Some(after_exp) = strip_kw(cur, "export") {
                is_exp = true;
                cur = after_exp;
            }
            if let Some(after_def) = strip_kw(cur, "default") {
                cur = after_def;
            }
            if let Some(after_async) = strip_kw(cur, "async") {
                cur = after_async;
            }
            let kw_matched = ["function", "class", "interface", "type"]
                .iter()
                .find_map(|kw| strip_kw(cur, kw));
            if let Some(after_kw) = kw_matched {
                if let Some((name, _)) = consume_ident_min3(after_kw, false) {
                    sym_name = Some(name);
                }
            } else {
                // Reset `default`/`async` and try `^[ \t]*(export[ \t]+)?(?:const|let)[ \t]+IDENT[ \t]*=[ \t]*(?:async[ \t]+)?(?:\([^)]*\)[ \t]*=>|function([^a-zA-Z0-9_]|$))`
                let mut cur_v = trim_leading_ws(line_body);
                let mut exp_v = false;
                if let Some(after_exp) = strip_kw(cur_v, "export") {
                    exp_v = true;
                    cur_v = after_exp;
                }
                if let Some(after_decl) =
                    strip_kw(cur_v, "const").or_else(|| strip_kw(cur_v, "let"))
                {
                    if let Some((name, after_name)) = consume_ident_min3(after_decl, false) {
                        let after_ws = trim_leading_ws(after_name);
                        if let Some(after_eq) = after_ws.strip_prefix('=') {
                            let mut rhs = trim_leading_ws(after_eq);
                            if let Some(after_async) = strip_kw(rhs, "async") {
                                rhs = after_async;
                            }
                            let is_arrow = rhs.starts_with('(')
                                && rhs[1..].find(')').is_some_and(|close| {
                                    trim_leading_ws(&rhs[2 + close..]).starts_with("=>")
                                });
                            let is_fn_expr = rhs.strip_prefix("function").is_some_and(|tail| {
                                tail.is_empty()
                                    || !(tail.as_bytes()[0].is_ascii_alphanumeric()
                                        || tail.as_bytes()[0] == b'_')
                            });
                            if is_arrow || is_fn_expr {
                                is_exp = exp_v;
                                sym_name = Some(name);
                            }
                        }
                    }
                }
            }
        }
        "py" => {
            let mut cur = trim_leading_ws(line_body);
            if let Some(after_async) = strip_kw(cur, "async") {
                cur = after_async;
            }
            if let Some(after_kw) = strip_kw(cur, "def").or_else(|| strip_kw(cur, "class")) {
                if let Some((name, _)) = consume_ident_min3(after_kw, false) {
                    sym_name = Some(name);
                    is_exp = !name.starts_with('_');
                }
            }
        }
        "go" => {
            if let Some(after_func) = strip_kw(line_body, "func") {
                let mut cur = after_func;
                if cur.starts_with('(') {
                    if let Some(close) = cur.find(')') {
                        let after_recv = &cur[close + 1..];
                        if after_recv.starts_with([' ', '\t']) {
                            cur = trim_leading_ws(after_recv);
                        } else {
                            cur = "";
                        }
                    } else {
                        cur = "";
                    }
                }
                if let Some((name, after_name)) = consume_ident_min3(cur, false) {
                    if trim_leading_ws(after_name).starts_with('(') {
                        sym_name = Some(name);
                        is_exp = name.as_bytes()[0].is_ascii_uppercase();
                    }
                }
            } else if let Some(after_type) = strip_kw(line_body, "type") {
                if let Some((name, after_name)) = consume_ident_min3(after_type, false) {
                    if after_name.starts_with([' ', '\t']) {
                        sym_name = Some(name);
                        is_exp = name.as_bytes()[0].is_ascii_uppercase();
                    }
                }
            }
        }
        "cs" | "java" => {
            let cur = trim_leading_ws(line_body);
            let vis = ["public", "private", "internal", "protected"]
                .iter()
                .find_map(|v| strip_kw(cur, v).map(|rest| (*v, rest)));
            if let Some((vis_kw, mut rest)) = vis {
                loop {
                    let next = [
                        "static", "async", "virtual", "override", "sealed", "abstract",
                    ]
                    .iter()
                    .find_map(|m| strip_kw(rest, m));
                    match next {
                        Some(r) => rest = r,
                        None => break,
                    }
                }
                if let Some(after_kind) = ["class", "interface", "struct", "record", "enum"]
                    .iter()
                    .find_map(|k| strip_kw(rest, k))
                {
                    if let Some((name, _)) = consume_ident_min3(after_kind, false) {
                        sym_name = Some(name);
                        is_exp = vis_kw == "public";
                    }
                }
            }
        }
        "rs" => {
            let mut cur = trim_leading_ws(line_body);
            let mut has_pub = false;
            if let Some(after_pub) = cur.strip_prefix("pub") {
                if let Some(after_paren) = after_pub.strip_prefix('(') {
                    if let Some(close) = after_paren.find(')') {
                        let tail = &after_paren[close + 1..];
                        if tail.starts_with([' ', '\t']) {
                            has_pub = true;
                            cur = trim_leading_ws(tail);
                        }
                    }
                } else if after_pub.starts_with([' ', '\t']) {
                    has_pub = true;
                    cur = trim_leading_ws(after_pub);
                }
            }
            if let Some(after_async) = strip_kw(cur, "async") {
                cur = after_async;
            }
            if let Some(after_kind) = ["fn", "struct", "enum", "trait"]
                .iter()
                .find_map(|k| strip_kw(cur, k))
            {
                if let Some((name, _)) = consume_ident_min3(after_kind, false) {
                    sym_name = Some(name);
                    is_exp = has_pub;
                }
            }
        }
        "ps1" | "sh" => {
            let cur = trim_leading_ws(line_body);
            if let Some(after_fn) = strip_kw(cur, "function") {
                if let Some((name, _)) = consume_ident_min3(after_fn, true) {
                    sym_name = Some(name);
                    is_exp = false;
                }
            } else if ext == "sh" {
                if let Some((name, after_name)) = consume_ident_min3(line_body, false) {
                    if let Some(after_parens) = after_name.strip_prefix("()") {
                        if trim_leading_ws(after_parens).starts_with('{') {
                            sym_name = Some(name);
                            is_exp = false;
                        }
                    }
                }
            }
        }
        _ => {}
    }

    let name = sym_name?;
    if SKIP_SYMBOL_NAMES.contains(&name) {
        return None;
    }
    Some(SymbolDecl {
        name: name.to_string(),
        exported: is_exp,
    })
}

fn is_diff_hunk_header(ln: &str) -> bool {
    let Some(rest) = ln.strip_prefix("@@ -") else {
        return false;
    };
    let Some(sp) = rest.find(" +") else {
        return false;
    };
    let old_part = &rest[..sp];
    let after_plus = &rest[sp + 2..];
    let Some(end_sp) = after_plus.find(" @@") else {
        return false;
    };
    let new_part = &after_plus[..end_sp];
    let valid_nums = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit() || b == b',');
    valid_nums(old_part) && valid_nums(new_part)
}

fn is_rust_test_attr(trimmed: &str) -> bool {
    trimmed == "#[test]"
        || trimmed.starts_with("#[test]")
        || trimmed.starts_with("#[tokio::test")
        || trimmed.starts_with("#[async_std::test")
        || trimmed.starts_with("#[rstest")
}

fn should_skip_symbol_file(path_val: &str, ignored: &[String]) -> bool {
    path_val.is_empty()
        || test_checkpoint_path(path_val)
        || (!ignored.is_empty() && test_path_match(path_val, ignored))
        || test_noise_file(path_val)
        || !test_code_path(path_val)
}

/// Detects removed symbols with dangling callers and newly added unreferenced
/// internal symbols across code files.
pub fn run(
    repo_root_raw: &str,
    base_sha_raw: &str,
    target_ref_raw: &str,
    ignore_dirty_paths: &str,
) -> Result<(String, i32), B3Error> {
    let ignored = split_path_csv_checked(ignore_dirty_paths, "SYMBOL_FAIL", true, None)?;
    let repo_root = normalize_repo_root(repo_root_raw)?;
    let scope = resolve_scope_target_and_base(
        &repo_root,
        target_ref_raw,
        base_sha_raw,
        &ignored,
        "SYMBOL_FAIL",
        "object",
    )?;
    let target_trim = scope.target_ref;
    let target_commit_sha = scope.target_commit_sha;
    let resolved_base = scope.base_sha;

    let no_env: [(&str, &str); 0] = [];
    let dl_args: Vec<&str> = if !target_trim.is_empty() {
        vec![
            "diff",
            "--no-ext-diff",
            "--no-renames",
            "-U0",
            &resolved_base,
            &target_commit_sha,
            "--",
        ]
    } else {
        vec![
            "diff",
            "--no-ext-diff",
            "--no-renames",
            "-U0",
            &resolved_base,
            "--",
        ]
    };
    let dl_res = run_git(&repo_root, &dl_args, &no_env, None)?;
    if dl_res.exit_code != 0 {
        return Err(fail(
            format!(
                "SYMBOL_FAIL: git diff -U0 failed: {}",
                git_err_detail(&dl_res)
            ),
            1,
        ));
    }

    let mut removed_by_file: BTreeMap<String, BTreeMap<String, bool>> = BTreeMap::new();
    let mut added_by_file: BTreeMap<String, BTreeMap<String, bool>> = BTreeMap::new();
    let mut old_file = String::new();
    let mut new_file = String::new();
    let mut skip_old = true;
    let mut skip_new = true;
    let mut in_hunk = false;
    let mut pending_rust_test = false;

    let dl_text = String::from_utf8_lossy(&dl_res.stdout);
    for raw_line in dl_text.lines() {
        let ln = raw_line.strip_suffix('\r').unwrap_or(raw_line);
        if ln.starts_with("diff --git ") {
            old_file.clear();
            new_file.clear();
            skip_old = true;
            skip_new = true;
            in_hunk = false;
            pending_rust_test = false;
            continue;
        }
        if !in_hunk && ln.starts_with("--- ") {
            if ln == "--- /dev/null" {
                old_file.clear();
                skip_old = true;
            } else {
                let cand = ln[4..].strip_prefix("a/").unwrap_or(&ln[4..]);
                old_file = normalize_path_value(cand);
                skip_old = should_skip_symbol_file(&old_file, &ignored);
            }
            continue;
        }
        if !in_hunk && ln.starts_with("+++ ") {
            if ln == "+++ /dev/null" {
                new_file.clear();
                skip_new = true;
            } else {
                let cand = ln[4..].strip_prefix("b/").unwrap_or(&ln[4..]);
                new_file = normalize_path_value(cand);
                skip_new = should_skip_symbol_file(&new_file, &ignored);
            }
            continue;
        }
        if is_diff_hunk_header(ln) {
            in_hunk = true;
            pending_rust_test = false;
            continue;
        }
        if !in_hunk {
            continue;
        }
        if let Some(body) = ln.strip_prefix('-') {
            if !skip_old {
                if let Some(sym) = extract_symbol_decl(&old_file, body) {
                    let entry = removed_by_file
                        .entry(old_file.clone())
                        .or_default()
                        .entry(sym.name)
                        .or_insert(false);
                    *entry = *entry || sym.exported;
                }
            }
        } else if let Some(body) = ln.strip_prefix('+') {
            if !skip_new {
                let is_rs = new_file.to_ascii_lowercase().ends_with(".rs");
                let tr = body.trim();
                if is_rs {
                    if is_rust_test_attr(tr) {
                        pending_rust_test = true;
                        continue;
                    }
                    if pending_rust_test
                        && (tr.is_empty() || tr.starts_with("#[") || tr.starts_with("//"))
                    {
                        continue;
                    }
                }
                let sym_opt = extract_symbol_decl(&new_file, body);
                let skip_as_test =
                    pending_rust_test && is_rs && body.contains("fn ") && sym_opt.is_some();
                if is_rs {
                    pending_rust_test = false;
                }
                if !skip_as_test {
                    if let Some(sym) = sym_opt {
                        let entry = added_by_file
                            .entry(new_file.clone())
                            .or_default()
                            .entry(sym.name)
                            .or_insert(false);
                        *entry = *entry || sym.exported;
                    }
                }
            }
        } else {
            pending_rust_test = false;
        }
    }

    if target_trim.is_empty() {
        let untracked = run_git_paths_z(
            &repo_root,
            &["ls-files", "--others", "--exclude-standard", "-z"],
            GitZMode::Names,
            "SYMBOL_FAIL",
            &no_env,
        )?;
        for u in sort_ordinal(untracked, false) {
            if should_skip_symbol_file(&u, &ignored) {
                continue;
            }
            let full = repo_root.join(u.replace('/', std::path::MAIN_SEPARATOR_STR));
            if !full.is_file() {
                continue;
            }
            if let Ok(content) = std::fs::read_to_string(&full) {
                let is_rs = u.to_ascii_lowercase().ends_with(".rs");
                let mut u_pending_test = false;
                for fl in content.lines() {
                    let tr = fl.trim();
                    if is_rs {
                        if is_rust_test_attr(tr) {
                            u_pending_test = true;
                            continue;
                        }
                        if u_pending_test
                            && (tr.is_empty() || tr.starts_with("#[") || tr.starts_with("//"))
                        {
                            continue;
                        }
                    }
                    let sym_opt = extract_symbol_decl(&u, fl);
                    let skip_as_test =
                        u_pending_test && is_rs && fl.contains("fn ") && sym_opt.is_some();
                    if is_rs {
                        u_pending_test = false;
                    }
                    if !skip_as_test {
                        if let Some(sym) = sym_opt {
                            let entry = added_by_file
                                .entry(u.clone())
                                .or_default()
                                .entry(sym.name)
                                .or_insert(false);
                            *entry = *entry || sym.exported;
                        }
                    }
                }
            }
        }
    }

    let mut added_anywhere: HashMap<String, bool> = HashMap::new();
    let mut removed_anywhere: HashSet<String> = HashSet::new();
    for syms in added_by_file.values() {
        for (s_name, &is_exp) in syms {
            let entry = added_anywhere.entry(s_name.clone()).or_insert(false);
            *entry = *entry || is_exp;
        }
    }
    for syms in removed_by_file.values() {
        for s_name in syms.keys() {
            removed_anywhere.insert(s_name.clone());
        }
    }

    let mut removed_syms = Vec::new();
    let mut exported_removed = Vec::new();
    let mut dangling_refs = Vec::new();
    let mut orphan_internal = Vec::new();
    let mut rem_checked = HashSet::new();
    let commit_prefix = format!("{target_commit_sha}:");
    let mut rem_candidates: Vec<(&str, bool, &str)> = Vec::new();

    for (f, syms) in &removed_by_file {
        for (s_name, &is_exp) in syms {
            let in_same_file = added_by_file.get(f).is_some_and(|m| m.contains_key(s_name));
            let same_file_exp = added_by_file
                .get(f)
                .and_then(|m| m.get(s_name))
                .copied()
                .unwrap_or(false);
            let in_any_file = added_anywhere.contains_key(s_name);
            let any_file_exp = added_anywhere.get(s_name).copied().unwrap_or(false);

            if in_same_file {
                if !is_exp || same_file_exp {
                    continue;
                }
            } else if in_any_file && (!is_exp || any_file_exp) {
                continue;
            }

            if !removed_syms.iter().any(|x| x == s_name) {
                removed_syms.push(s_name.clone());
            }
            if is_exp && !exported_removed.iter().any(|x| x == s_name) {
                exported_removed.push(s_name.clone());
            }
            if !rem_checked.insert(s_name.clone()) {
                continue;
            }
            rem_candidates.push((s_name.as_str(), in_same_file, f.as_str()));
        }
    }

    let run_symbol_grep = |flag_mode: &str,
                           syms: &[&str],
                           scope_files: Option<&[String]>|
     -> Result<crate::process::CmdOutput, B3Error> {
        let literal_files: Vec<String> = scope_files
            .map(|files| files.iter().map(|fp| format!(":(literal){fp}")).collect())
            .unwrap_or_default();
        let mut args: Vec<&str> = Vec::with_capacity(syms.len() * 2 + literal_files.len() + 13);
        args.push("grep");
        if target_trim.is_empty() {
            args.push("--untracked");
        }
        args.push("-w");
        args.push("-F");
        args.push(flag_mode);
        args.push("-z");
        for &sym in syms {
            args.push("-e");
            args.push(sym);
        }
        if !target_trim.is_empty() {
            args.push(&target_commit_sha);
        }
        args.push("--");
        if scope_files.is_some() {
            for lf in &literal_files {
                args.push(lf.as_str());
            }
        } else {
            args.extend([".", ":(exclude).b3", ":(exclude)*.md"]);
        }
        run_git(&repo_root, &args, &no_env, None)
    };

    let parse_grep_hit_files = |stdout: &[u8]| -> Vec<(String, String)> {
        let mut hit_files: Vec<(String, String)> = Vec::new();
        for raw_bytes in stdout.split(|&b| b == b'\0') {
            if raw_bytes.is_empty() {
                continue;
            }
            let raw_lossy = String::from_utf8_lossy(raw_bytes);
            let mut raw_path = raw_lossy.as_ref();
            if !target_trim.is_empty() {
                raw_path = raw_path.strip_prefix(&commit_prefix).unwrap_or(raw_path);
            }
            if raw_path.is_empty() {
                continue;
            }
            let np = normalize_path_value(raw_path);
            if should_skip_symbol_file(&np, &ignored) {
                continue;
            }
            if !hit_files.iter().any(|(r, _)| r == raw_path) {
                hit_files.push((raw_path.to_string(), np));
            }
        }
        hit_files
    };

    for chunk in rem_candidates.chunks(64) {
        let syms: Vec<&str> = chunk.iter().map(|&(s, _, _)| s).collect();
        let batch_res = run_symbol_grep("-l", &syms, None)?;
        if batch_res.exit_code > 1 {
            return Err(fail(
                format!("SYMBOL_FAIL: git grep failed for '{}'", syms[0]),
                1,
            ));
        }
        if batch_res.exit_code != 0 {
            continue;
        }
        let batch_hits = parse_grep_hit_files(&batch_res.stdout);
        if batch_hits.is_empty() {
            continue;
        }
        if chunk.len() == 1 {
            let (s_name, in_same_file, f) = chunk[0];
            let count = batch_hits
                .iter()
                .filter(|(_, np)| !(in_same_file && np.as_str() == f))
                .count();
            if count > 0 {
                dangling_refs.push(format!("{s_name}({count}f)"));
            }
            continue;
        }
        let raw_scope: Vec<String> = batch_hits.iter().map(|(raw, _)| raw.clone()).collect();
        let scoped = if raw_scope.len() <= 200 {
            Some(raw_scope.as_slice())
        } else {
            None
        };
        for &(s_name, in_same_file, f) in chunk {
            let g_res = run_symbol_grep("-l", &[s_name], scoped)?;
            if g_res.exit_code > 1 {
                return Err(fail(
                    format!("SYMBOL_FAIL: git grep failed for '{s_name}'"),
                    1,
                ));
            }
            if g_res.exit_code == 0 {
                let count = parse_grep_hit_files(&g_res.stdout)
                    .into_iter()
                    .filter(|(_, np)| !(in_same_file && np.as_str() == f))
                    .count();
                if count > 0 {
                    dangling_refs.push(format!("{s_name}({count}f)"));
                }
            }
        }
    }

    let mut added_candidates: Vec<(&str, &str)> = Vec::new();
    for (f, syms) in &added_by_file {
        if test_test_path(f) {
            continue;
        }
        for (s_name, &is_exp) in syms {
            if is_exp || removed_anywhere.contains(s_name) {
                continue;
            }
            added_candidates.push((f.as_str(), s_name.as_str()));
        }
    }

    for chunk in added_candidates.chunks(64) {
        let scoped_storage: Vec<String>;
        let scoped = if chunk.len() == 1 {
            None
        } else {
            let syms: Vec<&str> = chunk.iter().map(|&(_, s)| s).collect();
            let batch_res = run_symbol_grep("-l", &syms, None)?;
            if batch_res.exit_code > 1 {
                return Err(fail(
                    format!("SYMBOL_FAIL: git grep -l failed for '{}'", syms[0]),
                    1,
                ));
            }
            if batch_res.exit_code != 0 {
                for &(f, s_name) in chunk {
                    orphan_internal.push(format!("{f}:{s_name}"));
                }
                continue;
            }
            scoped_storage = parse_grep_hit_files(&batch_res.stdout)
                .into_iter()
                .map(|(raw, _)| raw)
                .collect();
            if scoped_storage.is_empty() {
                for &(f, s_name) in chunk {
                    orphan_internal.push(format!("{f}:{s_name}"));
                }
                continue;
            }
            if scoped_storage.len() <= 200 {
                Some(scoped_storage.as_slice())
            } else {
                None
            }
        };

        for &(f, s_name) in chunk {
            let gn_res = run_symbol_grep("-n", &[s_name], scoped)?;
            if gn_res.exit_code > 1 {
                return Err(fail(
                    format!("SYMBOL_FAIL: git grep -n failed for '{s_name}'"),
                    1,
                ));
            }
            let mut line_hits = 0usize;
            if gn_res.exit_code == 0 {
                for raw_row in gn_res.stdout.split(|&b| b == b'\n') {
                    let Some(nul_idx) = raw_row.iter().position(|&b| b == b'\0') else {
                        continue;
                    };
                    let raw_lossy = String::from_utf8_lossy(&raw_row[..nul_idx]);
                    let mut raw_path = raw_lossy.as_ref();
                    if !target_trim.is_empty() {
                        raw_path = raw_path.strip_prefix(&commit_prefix).unwrap_or(raw_path);
                    }
                    if raw_path.is_empty() {
                        continue;
                    }
                    let np = normalize_path_value(raw_path);
                    if should_skip_symbol_file(&np, &ignored) {
                        continue;
                    }
                    line_hits += 1;
                }
            }
            if line_hits <= 1 {
                orphan_internal.push(format!("{f}:{s_name}"));
            }
        }
    }

    let rem_out = if removed_syms.is_empty() {
        "none".to_string()
    } else {
        sort_ordinal(removed_syms, false).join(",")
    };
    let exp_out = if exported_removed.is_empty() {
        "none".to_string()
    } else {
        sort_ordinal(exported_removed, false).join(",")
    };
    let dan_out = if dangling_refs.is_empty() {
        "none".to_string()
    } else {
        sort_ordinal(dangling_refs, false).join(",")
    };
    let orp_out = if orphan_internal.is_empty() {
        "none".to_string()
    } else {
        sort_ordinal(orphan_internal, false).join(",")
    };

    let (term, code) = if dan_out != "none" {
        ("SYMBOL_FINDINGS", 2)
    } else if orp_out != "none" {
        ("SYMBOL_ADVISORY", 0)
    } else {
        ("SYMBOL_OK", 0)
    };

    let output = format!(
        "removed_symbols={rem_out}\nexported_removed={exp_out}\ndangling_refs={dan_out}\norphan_internal={orp_out}\n{term}"
    );
    Ok((output, code))
}
