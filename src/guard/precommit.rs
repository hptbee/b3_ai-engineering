use std::collections::HashSet;

use crate::error::{fail, B3Error};
use crate::fs::{
    normalize_repo_root, sort_ordinal, split_csv_list_as_paths, split_path_csv_checked,
    test_checkpoint_path, test_path_match, test_secret_path,
};
use crate::git::{run_git_paths_z, test_git_mid_operation, GitZMode};
use crate::guard::verify::{test_verify_receipt, validate_receipt_covers_paths};

/// Validates staged index state, allowed paths, secrets, checkpoint exclusion,
/// and optional verification receipt binding prior to commit.
pub fn run(
    repo_root_raw: &str,
    allowed_paths: &str,
    require_verify_receipt: &str,
    ignore_dirty_paths: &str,
    expected_cmd: &str,
    relevant_paths: &str,
) -> Result<String, B3Error> {
    run_with_pre_staged(
        repo_root_raw,
        allowed_paths,
        require_verify_receipt,
        ignore_dirty_paths,
        expected_cmd,
        relevant_paths,
        None,
    )
}

/// Same validation as `run`, reusing pre-fetched `git diff --cached --name-only -z`
/// output when provided by a caller such as `b3 hook`.
pub fn run_with_pre_staged(
    repo_root_raw: &str,
    allowed_paths: &str,
    require_verify_receipt: &str,
    ignore_dirty_paths: &str,
    expected_cmd: &str,
    relevant_paths: &str,
    pre_staged: Option<Vec<String>>,
) -> Result<String, B3Error> {
    let req_receipt = require_verify_receipt.trim();
    if req_receipt.is_empty()
        && (!expected_cmd.trim().is_empty() || !relevant_paths.trim().is_empty())
    {
        return Err(fail(
            "PRECOMMIT_FAIL: --expected-cmd and --relevant-paths require --require-verify-receipt",
            1,
        ));
    }

    let repo_root = normalize_repo_root(repo_root_raw)?;
    if let Some(mid_op) = test_git_mid_operation(&repo_root) {
        return Err(fail(
            format!("PRECOMMIT_FAIL: git operation in progress ({mid_op})"),
            1,
        ));
    }

    let allowed = split_path_csv_checked(allowed_paths, "PRECOMMIT_FAIL", false, None)?;
    let ignored = split_path_csv_checked(ignore_dirty_paths, "PRECOMMIT_FAIL", true, None)?;

    let no_env: [(&str, &str); 0] = [];
    let staged = match pre_staged {
        Some(paths) => paths,
        None => run_git_paths_z(
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
            "GIT_ERROR",
            &no_env,
        )?,
    };
    if staged.is_empty() {
        return Err(fail("PRECOMMIT_FAIL: nothing staged", 1));
    }

    let checkpoint_hits: Vec<String> = staged
        .iter()
        .filter(|p| {
            let low = p.to_ascii_lowercase();
            let is_dot_b3 = low == ".b3" || low.starts_with(".b3/");
            test_checkpoint_path(p) || (is_dot_b3 && !test_path_match(p, &allowed))
        })
        .cloned()
        .collect();
    if !checkpoint_hits.is_empty() {
        return Err(fail(
            format!(
                "PRECOMMIT_FAIL: checkpoint staged ({})",
                checkpoint_hits.join(", ")
            ),
            1,
        ));
    }

    if allowed.is_empty() {
        return Err(fail("PRECOMMIT_FAIL: missing --allowed-paths", 1));
    }

    let mut secret_hits = Vec::new();
    for p in &staged {
        if test_secret_path(p) && !allowed.iter().any(|a| a == p) {
            secret_hits.push(p.clone());
        }
    }
    if !secret_hits.is_empty() {
        return Err(fail(
            format!(
                "PRECOMMIT_FAIL: secret path staged without exact allow ({})",
                secret_hits.join(", ")
            ),
            1,
        ));
    }

    let undeclared: Vec<String> = staged
        .iter()
        .filter(|p| !test_path_match(p, &allowed))
        .cloned()
        .collect();
    if !undeclared.is_empty() {
        return Err(fail(
            format!(
                "PRECOMMIT_FAIL: undeclared staged path ({})",
                undeclared.join(", ")
            ),
            1,
        ));
    }

    if !req_receipt.is_empty() {
        let mut wt_args: Vec<String> = vec![
            "diff".into(),
            "--no-ext-diff".into(),
            "--no-renames".into(),
            "--ignore-submodules=none".into(),
            "--name-only".into(),
            "-z".into(),
            "--".into(),
        ];
        wt_args.extend(staged.iter().cloned());
        let mut wt_mismatch =
            run_git_paths_z(&repo_root, &wt_args, GitZMode::Names, "GIT_ERROR", &no_env)?;

        let staged_del = run_git_paths_z(
            &repo_root,
            &[
                "diff",
                "--no-ext-diff",
                "--no-renames",
                "--cached",
                "--diff-filter=D",
                "--name-only",
                "-z",
                "--",
            ],
            GitZMode::Names,
            "GIT_ERROR",
            &no_env,
        )?;
        for d in staged_del {
            let full_d = repo_root.join(d.replace('/', std::path::MAIN_SEPARATOR_STR));
            if full_d.exists() && !wt_mismatch.iter().any(|x| x == &d) {
                wt_mismatch.push(d);
            }
        }
        if !wt_mismatch.is_empty() {
            let sorted = sort_ordinal(wt_mismatch, false).join(", ");
            return Err(fail(
                format!("PRECOMMIT_FAIL: staged content differs from working tree ({sorted})"),
                1,
            ));
        }

        if !ignored.is_empty() {
            let staged_ign = sort_ordinal(
                staged
                    .iter()
                    .filter(|p| test_path_match(p, &ignored))
                    .cloned(),
                false,
            );
            if !staged_ign.is_empty() {
                return Err(fail(
                    format!(
                        "PRECOMMIT_FAIL: staged path excluded by ignore-dirty-paths ({})",
                        staged_ign.join(", ")
                    ),
                    1,
                ));
            }
        }

        let vr = test_verify_receipt(
            &repo_root,
            req_receipt,
            &ignored,
            expected_cmd,
            relevant_paths,
            "",
        );
        if vr.code != 0 {
            return Err(fail(
                format!(
                    "PRECOMMIT_FAIL: verification receipt check failed ({})",
                    vr.message
                ),
                1,
            ));
        }

        let scope_all = vr.relevant_paths_csv == "ALL" || {
            let sp = split_csv_list_as_paths(&vr.relevant_paths_csv);
            sp.iter().any(|p| p == ".")
        };
        let rec_paths = if vr.relevant_paths_csv == "ALL" {
            Vec::new()
        } else {
            split_csv_list_as_paths(&vr.relevant_paths_csv)
        };

        if let Some(outside) = validate_receipt_covers_paths(&vr.relevant_paths_csv, &staged) {
            return Err(fail(
                format!(
                    "PRECOMMIT_FAIL: staged path outside receipt scope ({})",
                    outside.join(", ")
                ),
                1,
            ));
        }

        let mut unstaged_args: Vec<String> = vec![
            "diff".into(),
            "--no-ext-diff".into(),
            "--no-renames".into(),
            "--ignore-submodules=none".into(),
            "--name-only".into(),
            "-z".into(),
            "--".into(),
        ];
        if !scope_all {
            unstaged_args.extend(rec_paths.iter().cloned());
        }
        let unstaged_raw = run_git_paths_z(
            &repo_root,
            &unstaged_args,
            GitZMode::Names,
            "GIT_ERROR",
            &no_env,
        )?;

        let mut untracked_args: Vec<String> = vec![
            "ls-files".into(),
            "--others".into(),
            "--exclude-standard".into(),
            "-z".into(),
        ];
        if !scope_all {
            untracked_args.push("--".into());
            untracked_args.extend(rec_paths.iter().cloned());
        }
        let untracked_raw = run_git_paths_z(
            &repo_root,
            &untracked_args,
            GitZMode::Names,
            "GIT_ERROR",
            &no_env,
        )?;

        let mut seen = HashSet::new();
        let mut unstaged_in_scope = Vec::new();
        for u in unstaged_raw.into_iter().chain(untracked_raw) {
            if u.is_empty() || test_checkpoint_path(&u) {
                continue;
            }
            if !ignored.is_empty() && test_path_match(&u, &ignored) {
                continue;
            }
            if !scope_all && !test_path_match(&u, &rec_paths) {
                continue;
            }
            if seen.insert(u.clone()) {
                unstaged_in_scope.push(u);
            }
        }
        if !unstaged_in_scope.is_empty() {
            let sorted = sort_ordinal(unstaged_in_scope, false).join(", ");
            return Err(fail(
                format!("PRECOMMIT_FAIL: unstaged changes in receipt scope ({sorted})"),
                1,
            ));
        }
    }

    Ok("PRECOMMIT_OK".to_string())
}
