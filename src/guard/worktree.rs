use std::path::PathBuf;

use crate::error::{fail, B3Error};
use crate::fs::{
    find_reparse_in_path_hierarchy, is_reparse_or_symlink, normalize_logical_path,
    normalize_path_value, resolve_unresolved_path, split_csv_list, test_worktree_root_overlap,
};
use crate::git::{get_canonical_git_path, is_hex40, run_git, test_git_mid_operation};

pub(crate) struct WorktreeIdentity {
    pub logical: PathBuf,
    pub top_norm: String,
    pub common_dir: String,
    pub git_dir: String,
    pub head: String,
}

pub(crate) fn resolve_safe_worktree_identity(
    raw_path: &str,
    missing_code: &str,
    not_git_code: &str,
    require_head: bool,
) -> Result<WorktreeIdentity, B3Error> {
    let logical = normalize_logical_path(raw_path)?;
    if let Some(reparse_hit) = find_reparse_in_path_hierarchy(&logical) {
        return Err(fail(
            format!(
                "WORKTREE_UNSAFE: unsafe_reparse_root({})",
                reparse_hit.display()
            ),
            2,
        ));
    }
    if !logical.is_dir() {
        return Err(fail(
            format!("WORKTREE_UNSAFE: {missing_code}({raw_path})"),
            2,
        ));
    }
    let dot_git = logical.join(".git");
    if is_reparse_or_symlink(&dot_git) {
        return Err(fail(
            format!(
                "WORKTREE_UNSAFE: unsafe_reparse_root({})",
                dot_git.display()
            ),
            2,
        ));
    }

    let no_env: [(&str, &str); 0] = [];
    let top_res = run_git(&logical, &["rev-parse", "--show-toplevel"], &no_env, None)?;
    let top_raw = String::from_utf8_lossy(&top_res.stdout).trim().to_string();
    if top_res.exit_code != 0 || top_raw.is_empty() {
        if not_git_code == "not_a_git_repo" {
            return Err(fail("WORKTREE_UNSAFE: not_a_git_repo", 2));
        }
        return Err(fail(
            format!("WORKTREE_UNSAFE: {not_git_code}({raw_path})"),
            2,
        ));
    }

    let head = if require_head {
        let head_res = run_git(&logical, &["rev-parse", "HEAD"], &no_env, None)?;
        let h = String::from_utf8_lossy(&head_res.stdout).trim().to_string();
        if head_res.exit_code != 0 || !is_hex40(&h) {
            return Err(fail("WORKTREE_UNSAFE: unborn_or_invalid_head", 2));
        }
        h
    } else {
        String::new()
    };

    let top_full = resolve_unresolved_path(&logical, &top_raw);
    if let Some(hit) = find_reparse_in_path_hierarchy(&top_full) {
        return Err(fail(
            format!("WORKTREE_UNSAFE: unsafe_reparse_root({})", hit.display()),
            2,
        ));
    }
    let top_dot_git = top_full.join(".git");
    if is_reparse_or_symlink(&top_dot_git) {
        return Err(fail(
            format!(
                "WORKTREE_UNSAFE: unsafe_reparse_root({})",
                top_dot_git.display()
            ),
            2,
        ));
    }

    let top_full = crate::fs::expand_windows_long_path(&top_full);
    let top_norm = normalize_path_value(&top_full.to_string_lossy());
    let common_dir = get_canonical_git_path(&logical, "--git-common-dir");
    let git_dir = get_canonical_git_path(&logical, "--git-dir");
    let (Some(common_dir), Some(git_dir)) = (common_dir, git_dir) else {
        if not_git_code == "not_a_git_repo" {
            return Err(fail("WORKTREE_UNSAFE: not_a_git_repo", 2));
        }
        return Err(fail(
            format!("WORKTREE_UNSAFE: {not_git_code}({raw_path})"),
            2,
        ));
    };

    Ok(WorktreeIdentity {
        logical,
        top_norm,
        common_dir,
        git_dir,
        head,
    })
}

fn paths_equal_fs(a: &str, b: &str, case_insensitive: bool) -> bool {
    if case_insensitive {
        a.eq_ignore_ascii_case(b)
    } else {
        a == b
    }
}

/// Validates Git worktree identity, linked-worktree isolation, base SHA,
/// and non-overlapping peer roots.
pub fn run(
    repo_root_raw: &str,
    expected_root: &str,
    expected_base_sha: &str,
    peer_roots: &str,
    require_isolated: bool,
) -> Result<String, B3Error> {
    let repo_id =
        resolve_safe_worktree_identity(repo_root_raw, "missing_repo_root", "not_a_git_repo", true)?;
    let actual_root_norm = repo_id.top_norm;
    let act_common = repo_id.common_dir;
    let act_git_dir = repo_id.git_dir;
    let head_raw = repo_id.head;

    if let Some(mid_op) = test_git_mid_operation(&repo_id.logical) {
        return Err(fail(
            format!("WORKTREE_UNSAFE: git_op_in_progress({mid_op})"),
            2,
        ));
    }

    let case_insensitive = cfg!(windows) || cfg!(target_os = "macos");
    let same_git_dir = paths_equal_fs(&act_git_dir, &act_common, case_insensitive);
    let is_linked = !same_git_dir;

    let peer_list = split_csv_list(peer_roots);
    let exp_trim = expected_root.trim();
    let has_expected_root = !exp_trim.is_empty();
    if require_isolated && !has_expected_root {
        return Err(fail(
            "WORKTREE_UNSAFE: missing_expected_root_for_isolation",
            2,
        ));
    }
    let check_isolation = require_isolated || (has_expected_root && !peer_list.is_empty());

    let mut exp_top_norm = String::new();
    let mut common_same = false;
    if has_expected_root {
        let exp_id = resolve_safe_worktree_identity(
            exp_trim,
            "expected_root_missing",
            "expected_root_not_git",
            false,
        )?;
        exp_top_norm = exp_id.top_norm;
        let exp_common = exp_id.common_dir;

        let top_same = paths_equal_fs(&actual_root_norm, &exp_top_norm, case_insensitive);
        if !act_common.is_empty() && !exp_common.is_empty() {
            common_same = paths_equal_fs(&act_common, &exp_common, case_insensitive);
        }
        if !top_same && !common_same {
            return Err(fail(
                format!("WORKTREE_UNSAFE: root_mismatch(expected={exp_top_norm},actual={actual_root_norm})"),
                2,
            ));
        }
        if check_isolation {
            if test_worktree_root_overlap(&actual_root_norm, &exp_top_norm, case_insensitive) {
                return Err(fail(
                    format!("WORKTREE_UNSAFE: parent_root_reused_or_nested(parent={exp_top_norm},worker={actual_root_norm})"),
                    2,
                ));
            }
            if !is_linked || !common_same {
                return Err(fail(
                    format!("WORKTREE_UNSAFE: not_isolated_linked_worktree(parent={exp_top_norm},worker={actual_root_norm})"),
                    2,
                ));
            }
        }
    }

    if !peer_list.is_empty() {
        let mut seen_tops = vec![actual_root_norm.clone()];
        for peer in &peer_list {
            let peer_id =
                resolve_safe_worktree_identity(peer, "missing_peer_root", "peer_not_git", false)?;
            let peer_top_norm = peer_id.top_norm;
            let peer_common = peer_id.common_dir;
            if !paths_equal_fs(&act_common, &peer_common, case_insensitive) {
                return Err(fail(
                    format!("WORKTREE_UNSAFE: peer_repo_mismatch(expected={act_common},actual={peer_common})"),
                    2,
                ));
            }
            if check_isolation
                && has_expected_root
                && test_worktree_root_overlap(&peer_top_norm, &exp_top_norm, case_insensitive)
            {
                return Err(fail(
                    format!("WORKTREE_UNSAFE: parent_root_reused_or_nested(parent={exp_top_norm},worker={peer_top_norm})"),
                    2,
                ));
            }
            for prev_top in &seen_tops {
                if test_worktree_root_overlap(&peer_top_norm, prev_top, case_insensitive) {
                    return Err(fail(
                        format!("WORKTREE_UNSAFE: duplicate_or_nested_worktree({peer_top_norm})"),
                        2,
                    ));
                }
            }
            seen_tops.push(peer_top_norm);
        }
    }

    let exp_base_trim = expected_base_sha.trim();
    if !exp_base_trim.is_empty() && head_raw != exp_base_trim {
        return Err(fail(
            format!("WORKTREE_UNSAFE: base_mismatch(expected={exp_base_trim},actual={head_raw})"),
            2,
        ));
    }

    let is_isolated = has_expected_root
        && common_same
        && is_linked
        && !test_worktree_root_overlap(&actual_root_norm, &exp_top_norm, case_insensitive);

    Ok(format!(
        "WORKTREE_OK: root={actual_root_norm} head={head_raw} common_dir={act_common} linked={is_linked} isolated={is_isolated}"
    ))
}
