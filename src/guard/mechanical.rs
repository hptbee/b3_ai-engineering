use std::collections::{HashMap, HashSet};
use std::path::Path;

use crate::error::{fail, B3Error};
use crate::fs::{
    convert_to_wave_paths, convert_to_wave_task_map, has_control_chars, is_hex64_lower,
    is_reparse_or_symlink, is_valid_task_id, is_windows_junction, normalize_path_value,
    normalize_repo_root, paths_equal_fs, sha256_file_hex, sort_ordinal, split_csv_list,
    split_path_csv_checked, test_binary_file, test_checkpoint_path, test_noise_file,
    test_ownership_path_match, test_path_match, test_secret_path, test_test_path,
    test_wave_path_contained, test_wave_path_overlap, test_worktree_root_overlap, WaveOverlap,
};
use crate::git::{
    git_err_detail, is_hex40, merge_base_is_ancestor, new_working_tree_oid,
    resolve_scope_target_and_base, run_git, run_git_paths_z, test_git_dir_mid_operation,
    test_git_mid_operation, test_repo_case_insensitive, GitZMode,
};
use crate::guard::verify::{get_submodule_entry_identity, get_symlink_blob_oid};
use crate::guard::worktree::resolve_safe_worktree_identity;

fn find_leftover_tag(line: &str) -> Option<&'static str> {
    let bytes = line.as_bytes();
    let is_w = |b: u8| b.is_ascii_alphanumeric() || b == b'_';

    let dbg_tok = concat!("deb", "ugger");
    let mut start = 0;
    while let Some(pos) = line[start..].find(dbg_tok) {
        let abs = start + pos;
        let left_ok = abs == 0 || !is_w(bytes[abs - 1]);
        let right = abs + dbg_tok.len();
        let right_ok = right == bytes.len() || !is_w(bytes[right]);
        if left_ok && right_ok {
            return Some(dbg_tok);
        }
        start = abs + 1;
    }

    let only_tok = concat!(".on", "ly(");
    if line.contains(only_tok) {
        return Some(only_tok);
    }
    let ts_tok = concat!("@ts-", "ignore");
    if line.contains(ts_tok) {
        return Some(ts_tok);
    }
    let eslint_tok = concat!("eslint-", "disable");
    if line.contains(eslint_tok) {
        return Some(eslint_tok);
    }

    for kw in ["TODO", "FIXME"] {
        let mut s = 0;
        while let Some(pos) = line[s..].find(kw) {
            let abs = s + pos;
            let left_ok = abs == 0 || !is_w(bytes[abs - 1]);
            if left_ok {
                let mut rest = line[abs + kw.len()..].trim_start_matches([' ', '\t']);
                if let Some(after_colon) = rest.strip_prefix(':') {
                    rest = after_colon.trim_start_matches([' ', '\t']);
                }
                if rest.is_empty() {
                    return Some("empty-todo");
                }
            }
            s = abs + 1;
        }
    }

    None
}

fn find_destructive_sql(line: &str) -> bool {
    let low = line.to_ascii_lowercase();
    let bytes = low.as_bytes();
    let is_w = |b: u8| b.is_ascii_alphanumeric() || b == b'_';
    for (first, second) in [
        ("drop", "table"),
        ("drop", "database"),
        ("truncate", "table"),
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
                        return true;
                    }
                }
            }
            start = abs + 1;
        }
    }
    false
}

fn parse_added_hunk_start(ln: &str) -> Option<usize> {
    let rest = ln.strip_prefix("@@ -")?;
    let sp = rest.find(" +")?;
    let old_part = &rest[..sp];
    if old_part.is_empty() || !old_part.bytes().all(|b| b.is_ascii_digit() || b == b',') {
        return None;
    }
    let after_plus = &rest[sp + 2..];
    let end_sp = after_plus.find(" @@")?;
    let new_part = &after_plus[..end_sp];
    let line_str = new_part.split(',').next()?;
    if line_str.is_empty() || !line_str.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    line_str.parse::<usize>().ok()
}

fn get_effective_repo_path_state(
    root: &Path,
    rel_path: &str,
    fail_prefix: &str,
) -> Result<String, B3Error> {
    let full = root.join(rel_path.replace('/', std::path::MAIN_SEPARATOR_STR));
    let exists_now = std::fs::symlink_metadata(&full).is_ok() || full.exists();

    if !test_wave_path_contained(root, rel_path) {
        if is_reparse_or_symlink(&full) && !is_windows_junction(&full) {
            let parent_rel = rel_path.rsplit_once('/').map(|(p, _)| p).unwrap_or("");
            if parent_rel.is_empty()
                || parent_rel == "."
                || test_wave_path_contained(root, parent_rel)
            {
                if let Some(l_sha) = get_symlink_blob_oid(root, rel_path)? {
                    return Ok(format!("120000:{l_sha}"));
                }
            }
        }
        return Ok("UNSAFE_REPARSE".to_string());
    }

    let no_env: [(&str, &str); 0] = [];
    let has_head = run_git(
        root,
        &["rev-parse", "--verify", "--quiet", "HEAD"],
        &no_env,
        None,
    )
    .map(|r| r.exit_code == 0)
    .unwrap_or(false);
    if has_head {
        let ca_head_res = run_git(
            root,
            &[
                "diff",
                "--no-ext-diff",
                "--cached",
                "--no-renames",
                "--name-only",
                "-z",
                "HEAD",
                "--",
                rel_path,
            ],
            &no_env,
            None,
        )?;
        if ca_head_res.exit_code != 0 {
            return Err(fail(
                format!("{fail_prefix}: git diff --cached failed for {rel_path}"),
                1,
            ));
        }
        if !ca_head_res.stdout.is_empty() {
            let iw_res = run_git(
                root,
                &[
                    "diff",
                    "--no-ext-diff",
                    "--no-renames",
                    "--name-only",
                    "-z",
                    "--",
                    rel_path,
                ],
                &no_env,
                None,
            )?;
            if iw_res.exit_code != 0 {
                return Err(fail(
                    format!("{fail_prefix}: git diff failed for {rel_path}"),
                    1,
                ));
            }
            let ca_del_res = run_git(
                root,
                &[
                    "diff",
                    "--no-ext-diff",
                    "--cached",
                    "--no-renames",
                    "--diff-filter=D",
                    "--name-only",
                    "-z",
                    "--",
                    rel_path,
                ],
                &no_env,
                None,
            )?;
            if ca_del_res.exit_code != 0 {
                return Err(fail(
                    format!("{fail_prefix}: git diff --cached -D failed for {rel_path}"),
                    1,
                ));
            }
            if !iw_res.stdout.is_empty() || (!ca_del_res.stdout.is_empty() && exists_now) {
                return Ok("INDEX_WT_DIVERGED".to_string());
            }
        }
    }

    if !exists_now {
        return Ok("DELETED".to_string());
    }
    if is_reparse_or_symlink(&full) {
        if !is_windows_junction(&full) {
            if let Some(l_sha) = get_symlink_blob_oid(root, rel_path)? {
                return Ok(format!("120000:{l_sha}"));
            }
        }
        return Ok("UNSAFE_REPARSE".to_string());
    }
    if full.is_file() {
        let h_res = run_git(root, &["hash-object", "--", rel_path], &no_env, None)?;
        let h_sha = String::from_utf8_lossy(&h_res.stdout).trim().to_string();
        if h_res.exit_code != 0 || !is_hex40(&h_sha) {
            let detail = if h_sha.is_empty() {
                git_err_detail(&h_res)
            } else {
                h_sha
            };
            return Err(fail(
                format!("{fail_prefix}: git hash-object failed for {rel_path}: {detail}"),
                1,
            ));
        }
        return Ok(format!("blob:{h_sha}"));
    }
    if full.is_dir() {
        if full.join(".git").exists() {
            if let Some(sub_id) = get_submodule_entry_identity(root, rel_path, "", 0)? {
                return Ok(format!("sub:{sub_id}"));
            }
        }
        return Ok("DIR".to_string());
    }
    Ok("DELETED".to_string())
}

fn is_protected_worker_path(norm: &str, protected_list: &[String], case_insensitive: bool) -> bool {
    let low = norm.to_ascii_lowercase();
    if low == ".b3"
        || low.starts_with(".b3/")
        || low.split('/').any(|s| s == ".git")
        || low == ".gitmodules"
        || low.ends_with("/.gitmodules")
    {
        return true;
    }
    test_ownership_path_match(norm, protected_list, case_insensitive)
}

#[allow(clippy::too_many_arguments)]
pub fn run(
    repo_root_raw: &str,
    base_sha_raw: &str,
    target_ref_raw: &str,
    allowed_paths_raw: &str,
    ignore_dirty_raw: &str,
    obsoletes_raw: &str,
    allow_mass_delete: bool,
    wave_specs_raw: &str,
    worker_changes_raw: &str,
    worker_roots_raw: &str,
    protected_paths_raw: &str,
    dirty_digests_raw: &str,
    has_dirty_digests_arg: bool,
) -> Result<(String, i32), B3Error> {
    let repo_root = normalize_repo_root(repo_root_raw)?;
    let case_insensitive = test_repo_case_insensitive(&repo_root);
    let repo_exists_mc = repo_root.is_dir();

    let has_wave_specs = !wave_specs_raw.trim().is_empty();
    let has_worker_changes = !worker_changes_raw.trim().is_empty();
    let has_worker_roots = !worker_roots_raw.trim().is_empty();
    let has_protected_arg = !protected_paths_raw.trim().is_empty();

    if has_worker_changes && has_worker_roots {
        return Err(fail(
            "MECHANICAL_FAIL: cannot specify both -WorkerChanges and -WorkerRoots",
            1,
        ));
    }
    if has_worker_changes && !has_wave_specs {
        return Err(fail(
            "MECHANICAL_FAIL: -WorkerChanges requires -WaveSpecs",
            1,
        ));
    }
    if has_worker_roots && !has_wave_specs {
        return Err(fail("MECHANICAL_FAIL: -WorkerRoots requires -WaveSpecs", 1));
    }
    if has_worker_roots && !target_ref_raw.trim().is_empty() {
        return Err(fail(
            "MECHANICAL_FAIL: -WorkerRoots cannot be combined with -TargetRef",
            1,
        ));
    }

    let mut protected_list = Vec::new();
    if has_protected_arg {
        let parsed_prot =
            convert_to_wave_paths(protected_paths_raw, false, false, "MECHANICAL_FAIL")?;
        for prot in &parsed_prot.paths {
            if prot == "." {
                return Err(fail("MECHANICAL_FAIL: invalid protected path '.'", 1));
            }
            if repo_exists_mc && !test_wave_path_contained(&repo_root, prot) {
                return Err(fail(
                    format!("MECHANICAL_FAIL: unsafe symlink or junction alias in path '{prot}'"),
                    1,
                ));
            }
        }
        protected_list = parsed_prot.paths;
    }

    let mut dirty_digest_map: HashMap<String, String> = HashMap::new();
    let mut dirty_digest_key_map: HashMap<String, String> = HashMap::new();
    if has_dirty_digests_arg {
        if has_control_chars(dirty_digests_raw) {
            return Err(fail("MECHANICAL_FAIL: invalid -DirtyDigests", 1));
        }
        let dd_trim = dirty_digests_raw.trim();
        if !dd_trim.is_empty() && dd_trim != "none" && dd_trim != "[]" {
            for dd_entry in dd_trim.split(';') {
                let dd_part = dd_entry.trim();
                if dd_part.is_empty() {
                    continue;
                }
                let Some(eq_idx) = dd_part.find('=') else {
                    return Err(fail(
                        format!("MECHANICAL_FAIL: invalid DirtyDigests entry '{dd_part}'"),
                        1,
                    ));
                };
                if eq_idx < 1 {
                    return Err(fail(
                        format!("MECHANICAL_FAIL: invalid DirtyDigests entry '{dd_part}'"),
                        1,
                    ));
                }
                let raw_dp = dd_part[..eq_idx].trim();
                let raw_dig = dd_part[eq_idx + 1..].trim();
                if raw_dp.contains(',') {
                    return Err(fail(
                        format!("MECHANICAL_FAIL: invalid DirtyDigests path '{raw_dp}'"),
                        1,
                    ));
                }
                let parsed_dp = convert_to_wave_paths(raw_dp, false, true, "MECHANICAL_FAIL")
                    .map_err(|_| {
                        fail(
                            format!("MECHANICAL_FAIL: invalid DirtyDigests path '{raw_dp}'"),
                            1,
                        )
                    })?;
                if parsed_dp.paths.len() != 1 {
                    return Err(fail(
                        format!("MECHANICAL_FAIL: invalid DirtyDigests path '{raw_dp}'"),
                        1,
                    ));
                }
                let dp_norm = parsed_dp.paths[0].clone();
                if test_checkpoint_path(&dp_norm) {
                    return Err(fail(
                        format!("MECHANICAL_FAIL: invalid DirtyDigests path '{dp_norm}'"),
                        1,
                    ));
                }
                if repo_exists_mc && !test_wave_path_contained(&repo_root, &dp_norm) {
                    return Err(fail(
                        format!(
                            "MECHANICAL_FAIL: unsafe symlink or junction alias in path '{dp_norm}'"
                        ),
                        1,
                    ));
                }
                let norm_dig = if raw_dig == "DELETED" {
                    "DELETED".to_string()
                } else {
                    raw_dig.to_ascii_lowercase()
                };
                if norm_dig != "DELETED" && !is_hex64_lower(&norm_dig) {
                    return Err(fail(
                        format!("MECHANICAL_FAIL: invalid DirtyDigests digest for '{dp_norm}'"),
                        1,
                    ));
                }
                let dd_key = if case_insensitive {
                    dp_norm.to_ascii_lowercase()
                } else {
                    dp_norm.clone()
                };
                if dirty_digest_key_map.contains_key(&dd_key) {
                    return Err(fail(
                        format!("MECHANICAL_FAIL: duplicate DirtyDigests path '{dp_norm}'"),
                        1,
                    ));
                }
                dirty_digest_key_map.insert(dd_key, dp_norm.clone());
                dirty_digest_map.insert(dp_norm, norm_dig);
            }
        }
    }

    let is_attributing = has_worker_changes || has_worker_roots;
    let mut ws_order: Vec<String> = Vec::new();
    let mut ws_map: HashMap<String, Vec<String>> = HashMap::new();
    let mut wc_order: Vec<String> = Vec::new();
    let mut wc_map: HashMap<String, Vec<String>> = HashMap::new();
    let mut wr_order: Vec<String> = Vec::new();
    let mut wr_map: HashMap<String, String> = HashMap::new();

    if has_wave_specs {
        let ws_parsed = convert_to_wave_task_map(
            wave_specs_raw,
            &repo_root,
            "MECHANICAL_FAIL",
            "WaveSpecs",
            "-WaveSpecs",
            true,
            true,
            true,
            None,
        )?;
        for ti in &ws_parsed.order {
            for pi in &ws_parsed.map[ti] {
                for prot in &protected_list {
                    if test_wave_path_overlap(pi, prot, case_insensitive) != WaveOverlap::None {
                        return Err(fail(
                            format!(
                                "MECHANICAL_FAIL: protected path '{pi}' overlaps single-writer boundary '{prot}'"
                            ),
                            1,
                        ));
                    }
                }
            }
        }
        if is_attributing {
            let b_trim = base_sha_raw.trim();
            if !is_hex40(&b_trim.to_ascii_lowercase()) {
                return Err(fail(
                    "MECHANICAL_FAIL: worker attribution requires explicit 40-hex -BaseSha",
                    1,
                ));
            }
            if let Some(mid_op) = test_git_mid_operation(&repo_root) {
                return Err(fail(
                    format!("MECHANICAL_FAIL: git operation in progress ({mid_op})"),
                    1,
                ));
            }
            for i in 0..ws_parsed.order.len() {
                for j in (i + 1)..ws_parsed.order.len() {
                    let ti = &ws_parsed.order[i];
                    let tj = &ws_parsed.order[j];
                    for pi in &ws_parsed.map[ti] {
                        for pj in &ws_parsed.map[tj] {
                            if test_wave_path_overlap(pi, pj, case_insensitive) != WaveOverlap::None
                            {
                                return Err(fail(
                                    format!(
                                        "MECHANICAL_FAIL: overlapping WaveSpecs '{pi}' and '{pj}' ({ti},{tj})"
                                    ),
                                    1,
                                ));
                            }
                        }
                    }
                }
            }
        }
        let ws_allowed_ids: HashSet<String> = ws_parsed.map.keys().cloned().collect();
        if has_worker_changes {
            let wc_parsed = convert_to_wave_task_map(
                worker_changes_raw,
                &repo_root,
                "MECHANICAL_FAIL",
                "WorkerChanges",
                "-WorkerChanges",
                false,
                true,
                true,
                Some(&ws_allowed_ids),
            )?;
            wc_order = wc_parsed.order;
            wc_map = wc_parsed.map;
        }
        if has_worker_roots {
            if has_control_chars(worker_roots_raw) {
                return Err(fail("MECHANICAL_FAIL: invalid -WorkerRoots", 1));
            }
            for wr_entry in worker_roots_raw.split(';') {
                let wr_trim = wr_entry.trim();
                if wr_trim.is_empty() {
                    continue;
                }
                let Some(eq_idx) = wr_trim.find('=') else {
                    return Err(fail(
                        format!(
                            "MECHANICAL_FAIL: invalid WorkerRoots entry '{wr_trim}' (expected TaskId=worktree_path)"
                        ),
                        1,
                    ));
                };
                let tid = wr_trim[..eq_idx].trim().to_string();
                let wt_val = wr_trim[eq_idx + 1..].trim().to_string();
                if tid.is_empty() || !is_valid_task_id(&tid) {
                    return Err(fail(
                        format!("MECHANICAL_FAIL: invalid task id '{tid}' in WorkerRoots"),
                        1,
                    ));
                }
                if wr_map.contains_key(&tid) {
                    return Err(fail(
                        format!("MECHANICAL_FAIL: duplicate task id '{tid}' in WorkerRoots"),
                        1,
                    ));
                }
                if !ws_parsed.map.contains_key(&tid) {
                    return Err(fail(
                        format!("MECHANICAL_FAIL: unknown task id '{tid}' in WorkerRoots"),
                        1,
                    ));
                }
                if wt_val.is_empty() {
                    return Err(fail(
                        format!(
                            "MECHANICAL_FAIL: empty worktree root for task '{tid}' in WorkerRoots"
                        ),
                        1,
                    ));
                }
                wr_order.push(tid.clone());
                let mapped = if wt_val == "none" || wt_val == "[]" {
                    String::new()
                } else {
                    wt_val
                };
                wr_map.insert(tid, mapped);
            }
            if wr_order.is_empty() {
                return Err(fail("MECHANICAL_FAIL: no tasks in -WorkerRoots", 1));
            }
        }
        ws_order = ws_parsed.order;
        ws_map = ws_parsed.map;
    }

    let allowed = split_path_csv_checked(allowed_paths_raw, "MECHANICAL_FAIL", false, None)?;
    let ignored = split_path_csv_checked(ignore_dirty_raw, "MECHANICAL_FAIL", true, None)?;
    let obsoletes_list = split_csv_list(obsoletes_raw);
    let base_kind = if is_attributing { "commit" } else { "object" };
    let scope = resolve_scope_target_and_base(
        &repo_root,
        target_ref_raw,
        base_sha_raw,
        &ignored,
        "MECHANICAL_FAIL",
        base_kind,
    )?;
    let target_trim = scope.target_ref;
    let target_commit_sha = scope.target_commit_sha;
    let resolved_base = scope.base_sha;

    let no_env: [(&str, &str); 0] = [];
    let ch_args: Vec<&str> = if !target_trim.is_empty() {
        vec![
            "diff",
            "--no-ext-diff",
            "--no-renames",
            "--name-only",
            "-z",
            &resolved_base,
            &target_commit_sha,
            "--",
        ]
    } else {
        vec![
            "diff",
            "--no-ext-diff",
            "--no-renames",
            "--name-only",
            "-z",
            &resolved_base,
            "--",
        ]
    };
    let ch_paths = run_git_paths_z(
        &repo_root,
        &ch_args,
        GitZMode::Names,
        "MECHANICAL_FAIL",
        &no_env,
    )?;

    let non_del_args: Vec<&str> = if !target_trim.is_empty() {
        vec![
            "diff",
            "--no-ext-diff",
            "--no-renames",
            "--diff-filter=d",
            "--name-only",
            "-z",
            &resolved_base,
            &target_commit_sha,
            "--",
        ]
    } else {
        vec![
            "diff",
            "--no-ext-diff",
            "--no-renames",
            "--diff-filter=d",
            "--name-only",
            "-z",
            &resolved_base,
            "--",
        ]
    };
    let non_del_paths = run_git_paths_z(
        &repo_root,
        &non_del_args,
        GitZMode::Names,
        "MECHANICAL_FAIL",
        &no_env,
    )?;

    let untracked = if !target_trim.is_empty() {
        Vec::new()
    } else {
        run_git_paths_z(
            &repo_root,
            &["ls-files", "--others", "--exclude-standard", "-z"],
            GitZMode::Names,
            "MECHANICAL_FAIL",
            &no_env,
        )?
    };

    let mut ca_base_ch_paths = Vec::new();
    let mut ca_base_non_del_paths = Vec::new();
    if target_trim.is_empty() {
        ca_base_ch_paths = run_git_paths_z(
            &repo_root,
            &[
                "diff",
                "--no-ext-diff",
                "--cached",
                "--no-renames",
                "--name-only",
                "-z",
                &resolved_base,
                "--",
            ],
            GitZMode::Names,
            "MECHANICAL_FAIL",
            &no_env,
        )?;
        if !ca_base_ch_paths.is_empty() {
            ca_base_non_del_paths = run_git_paths_z(
                &repo_root,
                &[
                    "diff",
                    "--no-ext-diff",
                    "--cached",
                    "--no-renames",
                    "--diff-filter=d",
                    "--name-only",
                    "-z",
                    &resolved_base,
                    "--",
                ],
                GitZMode::Names,
                "MECHANICAL_FAIL",
                &no_env,
            )?;
        }
    }

    let mut raw_changed_before_ign: HashSet<String> = HashSet::new();
    for rp in ch_paths
        .iter()
        .chain(ca_base_ch_paths.iter())
        .chain(untracked.iter())
    {
        if !rp.is_empty() && !test_checkpoint_path(rp) {
            raw_changed_before_ign.insert(rp.clone());
        }
    }
    if target_trim.is_empty() && (has_protected_arg || has_dirty_digests_arg) {
        let hd_dirty = run_git_paths_z(
            &repo_root,
            &[
                "diff",
                "--no-ext-diff",
                "--no-renames",
                "--name-only",
                "-z",
                "HEAD",
                "--",
            ],
            GitZMode::Names,
            "MECHANICAL_FAIL",
            &no_env,
        )?;
        let ca_dirty = run_git_paths_z(
            &repo_root,
            &[
                "diff",
                "--no-ext-diff",
                "--no-renames",
                "--cached",
                "--name-only",
                "-z",
                "--",
            ],
            GitZMode::Names,
            "MECHANICAL_FAIL",
            &no_env,
        )?;
        let wt_dirty = run_git_paths_z(
            &repo_root,
            &[
                "diff",
                "--no-ext-diff",
                "--no-renames",
                "--name-only",
                "-z",
                "--",
            ],
            GitZMode::Names,
            "MECHANICAL_FAIL",
            &no_env,
        )?;
        for rp in hd_dirty.into_iter().chain(ca_dirty).chain(wt_dirty) {
            if !rp.is_empty() && !test_checkpoint_path(&rp) {
                raw_changed_before_ign.insert(rp);
            }
        }
    }

    let mut protected_violations = Vec::new();
    if !protected_list.is_empty() {
        for rp in &raw_changed_before_ign {
            if test_ownership_path_match(rp, &protected_list, case_insensitive) {
                protected_violations.push(rp.clone());
            }
        }
    }

    let mut dirty_tamper_list = Vec::new();
    if has_dirty_digests_arg {
        for dp in sort_ordinal(dirty_digest_map.keys().cloned(), false) {
            let exp_dig = &dirty_digest_map[&dp];
            let full_dp = repo_root.join(dp.replace('/', std::path::MAIN_SEPARATOR_STR));
            let exists_dp = std::fs::symlink_metadata(&full_dp).is_ok() || full_dp.exists();
            if exp_dig == "DELETED" {
                if exists_dp {
                    dirty_tamper_list.push(dp);
                }
            } else if !exists_dp
                || is_reparse_or_symlink(&full_dp)
                || !full_dp.is_file()
                || sha256_file_hex(&full_dp).is_ok_and(|h| &h != exp_dig)
            {
                dirty_tamper_list.push(dp);
            }
        }
        if !ignored.is_empty() {
            for rp in &raw_changed_before_ign {
                if test_ownership_path_match(rp, &ignored, case_insensitive) {
                    let rp_key = if case_insensitive {
                        rp.to_ascii_lowercase()
                    } else {
                        rp.clone()
                    };
                    if !dirty_digest_key_map.contains_key(&rp_key)
                        && !dirty_tamper_list.iter().any(|x| x == rp)
                    {
                        dirty_tamper_list.push(rp.clone());
                    }
                }
            }
        }
    }

    let mut all_changed = Vec::new();
    let mut all_changed_keys: HashSet<String> = HashSet::new();
    for p in ch_paths
        .iter()
        .chain(untracked.iter())
        .chain(ca_base_ch_paths.iter())
    {
        if p.is_empty()
            || test_checkpoint_path(p)
            || test_ownership_path_match(p, &ignored, case_insensitive)
        {
            continue;
        }
        let k = if case_insensitive {
            p.to_ascii_lowercase()
        } else {
            p.clone()
        };
        if all_changed_keys.insert(k) {
            all_changed.push(p.clone());
        }
    }

    let mut non_del_changed = Vec::new();
    let mut non_del_set: HashSet<String> = HashSet::new();
    for p in non_del_paths
        .iter()
        .chain(untracked.iter())
        .chain(ca_base_non_del_paths.iter())
    {
        if p.is_empty()
            || test_checkpoint_path(p)
            || test_ownership_path_match(p, &ignored, case_insensitive)
        {
            continue;
        }
        if non_del_set.insert(p.clone()) {
            non_del_changed.push(p.clone());
        }
    }

    let mut scope_creep = Vec::new();
    if !allowed.is_empty() {
        for p in &all_changed {
            if !test_path_match(p, &allowed) {
                scope_creep.push(p.clone());
            }
        }
    }

    let mut leftover_hits: Vec<String> = Vec::new();
    let mut safety_hits: Vec<String> = Vec::new();
    for p in &non_del_changed {
        if test_secret_path(p) {
            safety_hits.push(format!("secret_path:{p}"));
        }
    }
    let mut sql_hit_count = 0usize;

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
                "MECHANICAL_FAIL: git diff -U0 failed: {}",
                git_err_detail(&dl_res)
            ),
            1,
        ));
    }
    let mut diff_texts: Vec<String> = Vec::new();
    if !dl_res.stdout.is_empty() {
        diff_texts.push(String::from_utf8_lossy(&dl_res.stdout).into_owned());
    }
    if target_trim.is_empty() && !ca_base_ch_paths.is_empty() {
        let dl_ca_res = run_git(
            &repo_root,
            &[
                "diff",
                "--no-ext-diff",
                "--cached",
                "--no-renames",
                "-U0",
                &resolved_base,
                "--",
            ],
            &no_env,
            None,
        )?;
        if dl_ca_res.exit_code != 0 {
            return Err(fail(
                format!(
                    "MECHANICAL_FAIL: git diff --cached -U0 failed: {}",
                    git_err_detail(&dl_ca_res)
                ),
                1,
            ));
        }
        if !dl_ca_res.stdout.is_empty() {
            diff_texts.push(String::from_utf8_lossy(&dl_ca_res.stdout).into_owned());
        }
    }

    for diff_txt in &diff_texts {
        let mut cur_file = String::new();
        let mut cur_line = 0usize;
        let mut skip_file = true;
        let mut in_hunk = false;
        for raw_line in diff_txt.lines() {
            let ln = raw_line.strip_suffix('\r').unwrap_or(raw_line);
            if ln.starts_with("diff --git ") {
                cur_file.clear();
                skip_file = true;
                in_hunk = false;
                continue;
            }
            if !in_hunk && ln.starts_with("+++ ") {
                if ln == "+++ /dev/null" {
                    cur_file.clear();
                    skip_file = true;
                } else {
                    let cand = ln[4..].strip_prefix("b/").unwrap_or(&ln[4..]);
                    cur_file = normalize_path_value(cand);
                    skip_file = cur_file.is_empty()
                        || test_checkpoint_path(&cur_file)
                        || test_path_match(&cur_file, &ignored)
                        || test_noise_file(&cur_file)
                        || cur_file.to_ascii_lowercase().ends_with(".md");
                }
                continue;
            }
            if let Some(start_line) = parse_added_hunk_start(ln) {
                cur_line = start_line;
                in_hunk = true;
                continue;
            }
            if !in_hunk || skip_file {
                continue;
            }
            if let Some(body) = ln.strip_prefix('+') {
                if let Some(tag) = find_leftover_tag(body) {
                    if leftover_hits.len() < 10 {
                        let entry = format!("{cur_file}:{cur_line}:{tag}");
                        if !leftover_hits.iter().any(|x| x == &entry) {
                            leftover_hits.push(entry);
                        }
                    }
                }
                if !test_test_path(&cur_file) && find_destructive_sql(body) && sql_hit_count < 10 {
                    let entry = format!("destructive_sql:{cur_file}:{cur_line}");
                    if !safety_hits.iter().any(|x| x == &entry) {
                        safety_hits.push(entry);
                        sql_hit_count += 1;
                    }
                }
                cur_line += 1;
            }
        }
    }

    for u in sort_ordinal(untracked.clone(), false) {
        if leftover_hits.len() >= 10 && sql_hit_count >= 10 {
            break;
        }
        if u.is_empty()
            || test_checkpoint_path(&u)
            || test_path_match(&u, &ignored)
            || test_noise_file(&u)
            || u.to_ascii_lowercase().ends_with(".md")
        {
            continue;
        }
        let full = repo_root.join(u.replace('/', std::path::MAIN_SEPARATOR_STR));
        if !full.is_file() || test_binary_file(&full) {
            continue;
        }
        let is_u_test = test_test_path(&u);
        if let Ok(content) = std::fs::read_to_string(&full) {
            for (idx, fl) in content.lines().enumerate() {
                let lno = idx + 1;
                if let Some(tag) = find_leftover_tag(fl) {
                    if leftover_hits.len() < 10 {
                        leftover_hits.push(format!("{u}:{lno}:{tag}"));
                    }
                }
                if !is_u_test && find_destructive_sql(fl) && sql_hit_count < 10 {
                    safety_hits.push(format!("destructive_sql:{u}:{lno}"));
                    sql_hit_count += 1;
                }
            }
        }
    }

    let mut candidate_del_set = HashSet::new();
    for dp in &ch_paths {
        if dp.is_empty()
            || test_checkpoint_path(dp)
            || test_ownership_path_match(dp, &ignored, case_insensitive)
            || test_noise_file(dp)
        {
            continue;
        }
        if !non_del_set.contains(dp) {
            candidate_del_set.insert(dp.clone());
        }
    }
    if !allow_mass_delete && candidate_del_set.len() >= 10 {
        let del_target = if !target_trim.is_empty() {
            target_commit_sha.clone()
        } else {
            new_working_tree_oid(&repo_root, "MECHANICAL_FAIL", true)?
        };
        let del_paths = run_git_paths_z(
            &repo_root,
            &[
                "diff",
                "--no-ext-diff",
                "-M",
                "--diff-filter=D",
                "--name-only",
                "-z",
                &resolved_base,
                &del_target,
                "--",
            ],
            GitZMode::Names,
            "MECHANICAL_FAIL",
            &no_env,
        )?;
        let mut deleted_list = Vec::new();
        for dp in del_paths {
            if !dp.is_empty()
                && !test_checkpoint_path(&dp)
                && !test_ownership_path_match(&dp, &ignored, case_insensitive)
                && !test_noise_file(&dp)
                && !deleted_list.iter().any(|x| x == &dp)
            {
                deleted_list.push(dp);
            }
        }
        if deleted_list.len() >= 10 {
            safety_hits.push(format!("mass_delete:{}f", deleted_list.len()));
        }
    }

    let mut obsolete_hits = Vec::new();
    if !obsoletes_list.is_empty() {
        let mut target_existing_paths = HashSet::new();
        if !target_trim.is_empty() {
            let mut ls_path_args = Vec::new();
            for tok in &obsoletes_list {
                let nt = normalize_path_value(tok);
                if !nt.is_empty()
                    && !nt.starts_with('-')
                    && !nt.contains(':')
                    && !nt.split('/').any(|s| s == "..")
                    && !ls_path_args.iter().any(|x| x == &nt)
                {
                    ls_path_args.push(nt);
                }
            }
            if !ls_path_args.is_empty() {
                let mut args: Vec<String> = vec![
                    "ls-tree".into(),
                    "--name-only".into(),
                    "-z".into(),
                    target_commit_sha.clone(),
                    "--".into(),
                ];
                args.extend(ls_path_args);
                for lp in run_git_paths_z(
                    &repo_root,
                    &args,
                    GitZMode::Names,
                    "MECHANICAL_FAIL",
                    &no_env,
                )? {
                    if !lp.is_empty() {
                        target_existing_paths.insert(lp);
                    }
                }
            }
        }

        let mut batch_args: Vec<String> = vec!["grep".into()];
        if target_trim.is_empty() {
            batch_args.push("--untracked".into());
        }
        batch_args.push("-l".into());
        batch_args.push("-F".into());
        for tok in &obsoletes_list {
            batch_args.push("-e".into());
            batch_args.push(tok.clone());
        }
        if !target_trim.is_empty() {
            batch_args.push(target_commit_sha.clone());
        }
        batch_args.extend(
            [
                "--",
                ".",
                ":(exclude).b3/ship",
                ":(exclude).b3/research-ship",
                ":(exclude).b3/autodev",
            ]
            .into_iter()
            .map(String::from),
        );
        let batch_res = run_git(&repo_root, &batch_args, &no_env, None)?;
        if batch_res.exit_code > 1 {
            return Err(fail("MECHANICAL_FAIL: git grep failed for obsoletes", 1));
        }

        let mut batch_hit_files = Vec::new();
        let obs_prefix = format!("{target_commit_sha}:");
        if batch_res.exit_code == 0 && !batch_res.stdout.is_empty() {
            for row in String::from_utf8_lossy(&batch_res.stdout).lines() {
                let mut gp = row.trim();
                if gp.is_empty() {
                    continue;
                }
                if !target_trim.is_empty() {
                    gp = gp.strip_prefix(&obs_prefix).unwrap_or(gp);
                }
                let gp_norm = normalize_path_value(gp);
                if gp_norm.is_empty()
                    || test_checkpoint_path(&gp_norm)
                    || (!ignored.is_empty() && test_path_match(&gp_norm, &ignored))
                {
                    continue;
                }
                if !batch_hit_files.iter().any(|x| x == &gp_norm) {
                    batch_hit_files.push(gp_norm);
                }
            }
        }

        for tok in &obsoletes_list {
            let norm_tok = normalize_path_value(tok);
            let exists_path = if norm_tok.is_empty() {
                false
            } else if !target_trim.is_empty() {
                if norm_tok.starts_with('-')
                    || norm_tok.contains(':')
                    || norm_tok.split('/').any(|s| s == "..")
                {
                    let obj = format!("{target_commit_sha}:{norm_tok}");
                    run_git(&repo_root, &["cat-file", "-e", &obj], &no_env, None)
                        .map(|r| r.exit_code == 0)
                        .unwrap_or(false)
                } else {
                    target_existing_paths.contains(&norm_tok)
                }
            } else {
                let full_t = repo_root.join(norm_tok.replace('/', std::path::MAIN_SEPARATOR_STR));
                std::fs::symlink_metadata(&full_t).is_ok() || full_t.exists()
            };

            let mut grep_count = 0usize;
            if !batch_hit_files.is_empty() {
                if obsoletes_list.len() == 1 {
                    grep_count = batch_hit_files.len();
                } else {
                    let mut single_args: Vec<String> = vec!["grep".into()];
                    if target_trim.is_empty() {
                        single_args.push("--untracked".into());
                    }
                    single_args.extend(["-l".into(), "-F".into(), "-e".into(), tok.clone()]);
                    if !target_trim.is_empty() {
                        single_args.push(target_commit_sha.clone());
                    }
                    single_args.push("--".into());
                    single_args.extend(batch_hit_files.iter().cloned());
                    let single_res = run_git(&repo_root, &single_args, &no_env, None)?;
                    if single_res.exit_code > 1 {
                        return Err(fail(
                            format!("MECHANICAL_FAIL: git grep failed for obsolete '{tok}'"),
                            1,
                        ));
                    }
                    if single_res.exit_code == 0 && !single_res.stdout.is_empty() {
                        for row in String::from_utf8_lossy(&single_res.stdout).lines() {
                            let mut gp = row.trim();
                            if gp.is_empty() {
                                continue;
                            }
                            if !target_trim.is_empty() {
                                gp = gp.strip_prefix(&obs_prefix).unwrap_or(gp);
                            }
                            let gp_norm = normalize_path_value(gp);
                            if gp_norm.is_empty()
                                || test_checkpoint_path(&gp_norm)
                                || (!ignored.is_empty() && test_path_match(&gp_norm, &ignored))
                            {
                                continue;
                            }
                            grep_count += 1;
                        }
                    }
                }
            }
            if exists_path && grep_count > 0 {
                obsolete_hits.push(format!("{tok}(exists+{grep_count}f)"));
            } else if exists_path {
                obsolete_hits.push(format!("{tok}(exists)"));
            } else if grep_count > 0 {
                obsolete_hits.push(format!("{tok}({grep_count}f)"));
            }
        }
    }

    let mut ov_status = String::new();
    let mut ov_violations_out = String::new();
    if has_wave_specs {
        if !is_attributing {
            ov_status = "UNVERIFIED_COMBINED_ONLY".to_string();
            ov_violations_out = "unverified".to_string();
        } else {
            let resolve_misowned = |path_arg: &str, owner_tid: &str| -> String {
                let mut other_owners = Vec::new();
                for other_tid in &ws_order {
                    if other_tid == owner_tid {
                        continue;
                    }
                    if test_ownership_path_match(path_arg, &ws_map[other_tid], case_insensitive) {
                        other_owners.push(other_tid.clone());
                    }
                }
                if !other_owners.is_empty() {
                    let sorted_other = sort_ordinal(other_owners, false);
                    format!("{path_arg}({owner_tid}->{})", sorted_other[0])
                } else {
                    format!("{path_arg}({owner_tid}->unowned)")
                }
            };

            let mut ov_violations = Vec::new();
            let mut attributed_paths: Vec<String> = Vec::new();
            let present_tasks: HashSet<String>;

            if has_worker_changes {
                present_tasks = wc_map.keys().cloned().collect();
                for tid in &wc_order {
                    let tid_owned = &ws_map[tid];
                    for wp in &wc_map[tid] {
                        attributed_paths.push(wp.clone());
                        if is_protected_worker_path(wp, &protected_list, case_insensitive) {
                            ov_violations.push(format!("{wp}({tid}->protected)"));
                            continue;
                        }
                        if test_ownership_path_match(wp, &ignored, case_insensitive) {
                            ov_violations.push(format!("{wp}({tid}->user_dirty)"));
                            continue;
                        }
                        let wp_key = if case_insensitive {
                            wp.to_ascii_lowercase()
                        } else {
                            wp.clone()
                        };
                        if test_ownership_path_match(wp, tid_owned, case_insensitive) {
                            if !all_changed_keys.contains(&wp_key) {
                                ov_violations.push(format!("{wp}({tid}->phantom)"));
                            }
                            continue;
                        }
                        ov_violations.push(resolve_misowned(wp, tid));
                    }
                }
            } else {
                present_tasks = wr_map.keys().cloned().collect();
                let parent_wt_id = resolve_safe_worktree_identity(
                    repo_root_raw,
                    "missing_repo_root",
                    "not_a_git_repo",
                    true,
                )?;
                let parent_top_norm = parent_wt_id.top_norm;
                let parent_common = parent_wt_id.common_dir;
                let mut seen_wt_tops = vec![parent_top_norm.clone()];

                for tid in &wr_order {
                    let wt_raw = &wr_map[tid];
                    if wt_raw.is_empty() {
                        continue;
                    }
                    let w_id = resolve_safe_worktree_identity(
                        wt_raw,
                        "missing_worker_root",
                        "worker_not_git",
                        true,
                    )?;
                    if let Some(w_mid) = test_git_dir_mid_operation(&w_id.git_dir_path) {
                        return Err(fail(
                            format!("WORKTREE_UNSAFE: git_op_in_progress({w_mid})"),
                            2,
                        ));
                    }
                    if !paths_equal_fs(&w_id.common_dir, &parent_common, case_insensitive) {
                        return Err(fail(
                            format!(
                                "WORKTREE_UNSAFE: peer_repo_mismatch(expected={parent_common},actual={})",
                                w_id.common_dir
                            ),
                            2,
                        ));
                    }
                    let wt_same_git =
                        paths_equal_fs(&w_id.git_dir, &w_id.common_dir, case_insensitive);
                    if wt_same_git
                        || test_worktree_root_overlap(
                            &w_id.top_norm,
                            &parent_top_norm,
                            case_insensitive,
                        )
                    {
                        return Err(fail(
                            format!(
                                "WORKTREE_UNSAFE: not_isolated_linked_worktree(parent={parent_top_norm},worker={})",
                                w_id.top_norm
                            ),
                            2,
                        ));
                    }
                    for prev_top in &seen_wt_tops {
                        if test_worktree_root_overlap(&w_id.top_norm, prev_top, case_insensitive) {
                            return Err(fail(
                                format!(
                                    "WORKTREE_UNSAFE: duplicate_or_nested_worktree({})",
                                    w_id.top_norm
                                ),
                                2,
                            ));
                        }
                    }
                    seen_wt_tops.push(w_id.top_norm.clone());

                    let w_top_path = Path::new(&w_id.top_norm);
                    if !merge_base_is_ancestor(
                        w_top_path,
                        &resolved_base,
                        &w_id.head,
                        "WORKTREE_UNSAFE",
                    )
                    .unwrap_or(false)
                    {
                        return Err(fail(
                            format!(
                                "WORKTREE_UNSAFE: base_not_ancestor_of_worker(task={tid},base={resolved_base},head={})",
                                w_id.head
                            ),
                            2,
                        ));
                    }

                    let w_diff = run_git_paths_z(
                        w_top_path,
                        &[
                            "diff",
                            "--no-ext-diff",
                            "--no-renames",
                            "--name-only",
                            "-z",
                            &resolved_base,
                            "--",
                        ],
                        GitZMode::Names,
                        "MECHANICAL_FAIL",
                        &no_env,
                    )?;
                    let w_ca = run_git_paths_z(
                        w_top_path,
                        &[
                            "diff",
                            "--no-ext-diff",
                            "--cached",
                            "--no-renames",
                            "--name-only",
                            "-z",
                            &resolved_base,
                            "--",
                        ],
                        GitZMode::Names,
                        "MECHANICAL_FAIL",
                        &no_env,
                    )?;
                    let w_un = run_git_paths_z(
                        w_top_path,
                        &["ls-files", "--others", "--exclude-standard", "-z"],
                        GitZMode::Names,
                        "MECHANICAL_FAIL",
                        &no_env,
                    )?;
                    let mut w_changed = Vec::new();
                    let mut w_seen = HashSet::new();
                    for wp in w_diff.into_iter().chain(w_ca).chain(w_un) {
                        if !wp.is_empty() && !test_checkpoint_path(&wp) && w_seen.insert(wp.clone())
                        {
                            w_changed.push(wp);
                        }
                    }

                    let tid_owned = &ws_map[tid];
                    for wp in &w_changed {
                        attributed_paths.push(wp.clone());
                        if is_protected_worker_path(wp, &protected_list, case_insensitive) {
                            ov_violations.push(format!("{wp}({tid}->protected)"));
                            continue;
                        }
                        if test_ownership_path_match(wp, &ignored, case_insensitive) {
                            ov_violations.push(format!("{wp}({tid}->user_dirty)"));
                            continue;
                        }
                        if !test_ownership_path_match(wp, tid_owned, case_insensitive) {
                            ov_violations.push(resolve_misowned(wp, tid));
                            continue;
                        }
                        let wp_key = if case_insensitive {
                            wp.to_ascii_lowercase()
                        } else {
                            wp.clone()
                        };
                        if !all_changed_keys.contains(&wp_key) {
                            ov_violations.push(format!("{wp}({tid}->content_mismatch)"));
                            continue;
                        }
                        let wt_state =
                            get_effective_repo_path_state(w_top_path, wp, "MECHANICAL_FAIL")?;
                        let root_state =
                            get_effective_repo_path_state(&repo_root, wp, "MECHANICAL_FAIL")?;
                        if wt_state == "UNSAFE_REPARSE"
                            || root_state == "UNSAFE_REPARSE"
                            || wt_state == "INDEX_WT_DIVERGED"
                            || root_state == "INDEX_WT_DIVERGED"
                            || wt_state != root_state
                        {
                            ov_violations.push(format!("{wp}({tid}->content_mismatch)"));
                        }
                    }
                }
            }

            for gp in &all_changed {
                if !attributed_paths
                    .iter()
                    .any(|ap| paths_equal_fs(gp, ap, case_insensitive))
                {
                    ov_violations.push(format!("{gp}(unattributed)"));
                }
            }
            for pv in &protected_violations {
                ov_violations.push(format!("{pv}(protected)"));
            }
            for dt in &dirty_tamper_list {
                ov_violations.push(format!("{dt}(dirty_tamper)"));
            }

            let mut missing_workers = Vec::new();
            for tid in &ws_order {
                if !present_tasks.contains(tid) {
                    missing_workers.push(format!("{tid}(missing_worker)"));
                }
            }

            if !ov_violations.is_empty() {
                ov_status = "VIOLATION".to_string();
                ov_violations_out = sort_ordinal(ov_violations, false).join(",");
            } else if !missing_workers.is_empty() {
                ov_status = "PARTIAL_ATTRIBUTION".to_string();
                ov_violations_out = sort_ordinal(missing_workers, false).join(",");
            } else {
                ov_status = if has_worker_changes {
                    "CALLER_ATTRIBUTED".to_string()
                } else {
                    "VERIFIED_PER_WORKER".to_string()
                };
                ov_violations_out = "none".to_string();
            }
        }
    }

    let sc_out = if scope_creep.is_empty() {
        "none".to_string()
    } else {
        sort_ordinal(scope_creep, false).join(",")
    };
    let lo_out = if leftover_hits.is_empty() {
        "none".to_string()
    } else {
        leftover_hits.join(",")
    };
    let ob_out = if obsolete_hits.is_empty() {
        "none".to_string()
    } else {
        sort_ordinal(obsolete_hits, false).join(",")
    };
    let sf_out = if safety_hits.is_empty() {
        "none".to_string()
    } else {
        sort_ordinal(safety_hits, false).join(",")
    };
    let pv_out = if protected_violations.is_empty() {
        "none".to_string()
    } else {
        sort_ordinal(protected_violations, false).join(",")
    };
    let dt_out = if dirty_tamper_list.is_empty() {
        "none".to_string()
    } else {
        sort_ordinal(dirty_tamper_list, false).join(",")
    };

    let mut lines = vec![
        format!("scope_creep={sc_out}"),
        format!("leftovers={lo_out}"),
        format!("obsolete_hits={ob_out}"),
        format!("safety_hits={sf_out}"),
    ];
    if has_protected_arg {
        lines.push(format!("protected_violations={pv_out}"));
    }
    if has_dirty_digests_arg {
        lines.push(format!("dirty_tamper={dt_out}"));
    }
    if has_wave_specs {
        lines.push(format!("ownership_verification={ov_status}"));
        lines.push(format!("ownership_violations={ov_violations_out}"));
    }

    let ov_ok = !has_wave_specs
        || matches!(
            ov_status.as_str(),
            "UNVERIFIED_COMBINED_ONLY" | "CALLER_ATTRIBUTED" | "VERIFIED_PER_WORKER"
        );
    let (term, code) = if sc_out == "none"
        && lo_out == "none"
        && ob_out == "none"
        && sf_out == "none"
        && pv_out == "none"
        && dt_out == "none"
        && ov_ok
    {
        ("MECHANICAL_OK", 0)
    } else {
        ("MECHANICAL_FINDINGS", 2)
    };
    lines.push(term.to_string());
    Ok((lines.join("\n"), code))
}
