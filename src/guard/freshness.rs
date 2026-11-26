use crate::error::{fail, B3Error};
use crate::fs::{
    normalize_repo_root, sort_ordinal, split_path_csv_checked, test_checkpoint_path,
    test_path_match,
};
use crate::git::{assert_valid_git_rev, merge_base_is_ancestor, run_git_paths_z, GitZMode};

/// Validates task/plan freshness against committed and uncommitted changes.
/// Returns `Ok("FRESH")` on exit 0, or `B3Error` with exit code `2` on stale
/// or `1` on validation/Git failure.
pub fn run(
    repo_root_raw: &str,
    approach_at_sha: &str,
    task_base_sha: &str,
    watched_paths: &str,
    owned_files: &str,
    ignore_dirty_paths: &str,
) -> Result<String, B3Error> {
    if approach_at_sha.is_empty() {
        return Err(fail("FRESHNESS_FAIL: missing --approach-at-sha", 1));
    }
    if task_base_sha.is_empty() {
        return Err(fail("FRESHNESS_FAIL: missing --task-base-sha", 1));
    }

    let watched = split_path_csv_checked(watched_paths, "FRESHNESS_FAIL", false, None)?;
    if watched.is_empty() {
        return Err(fail("FRESHNESS_FAIL: missing --watched-paths", 1));
    }
    let owned = split_path_csv_checked(owned_files, "FRESHNESS_FAIL", false, None)?;
    let ignored = split_path_csv_checked(ignore_dirty_paths, "FRESHNESS_FAIL", true, None)?;

    let repo_root = normalize_repo_root(repo_root_raw)?;
    let resolved_approach = assert_valid_git_rev(
        &repo_root,
        approach_at_sha.trim(),
        "commit",
        "FRESHNESS_FAIL",
        "--approach-at-sha",
    )?;
    let resolved_task_base = assert_valid_git_rev(
        &repo_root,
        task_base_sha.trim(),
        "commit",
        "FRESHNESS_FAIL",
        "--task-base-sha",
    )?;
    let resolved_head =
        assert_valid_git_rev(&repo_root, "HEAD", "commit", "FRESHNESS_FAIL", "HEAD")?;

    if !merge_base_is_ancestor(
        &repo_root,
        &resolved_task_base,
        &resolved_head,
        "FRESHNESS_FAIL",
    )? {
        return Err(fail("STALE: HEAD is not a descendant of task_base", 2));
    }
    if !merge_base_is_ancestor(
        &repo_root,
        &resolved_approach,
        &resolved_head,
        "FRESHNESS_FAIL",
    )? {
        return Err(fail(
            "STALE: HEAD is not a descendant of approach_at_sha",
            2,
        ));
    }

    let no_env: [(&str, &str); 0] = [];
    let committed = run_git_paths_z(
        &repo_root,
        &[
            "diff",
            "--no-ext-diff",
            "--no-renames",
            "--name-only",
            "-z",
            &resolved_approach,
            &resolved_head,
            "--",
        ],
        GitZMode::Names,
        "GIT_ERROR",
        &no_env,
    )?;

    let committed_hits = sort_ordinal(
        committed
            .into_iter()
            .filter(|p| !test_checkpoint_path(p) && test_path_match(p, &watched)),
        false,
    );
    if !committed_hits.is_empty() {
        return Err(fail(
            format!(
                "STALE: committed change in watched_paths ({})",
                committed_hits.join(", ")
            ),
            2,
        ));
    }

    let read_only_watched: Vec<String> = watched
        .into_iter()
        .filter(|w| !test_path_match(w, &owned))
        .collect();

    if !read_only_watched.is_empty() {
        let wt_diff = run_git_paths_z(
            &repo_root,
            &[
                "diff",
                "--no-ext-diff",
                "--no-renames",
                "--name-only",
                "-z",
                &resolved_approach,
                "--",
            ],
            GitZMode::Names,
            "GIT_ERROR",
            &no_env,
        )?;
        let cached = run_git_paths_z(
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
        )?;
        let untracked = run_git_paths_z(
            &repo_root,
            &["ls-files", "--others", "--exclude-standard", "-z"],
            GitZMode::Names,
            "GIT_ERROR",
            &no_env,
        )?;

        let ro_hits = sort_ordinal(
            wt_diff
                .into_iter()
                .chain(cached)
                .chain(untracked)
                .filter(|p| {
                    !p.is_empty()
                        && !test_checkpoint_path(p)
                        && !test_path_match(p, &ignored)
                        && !test_path_match(p, &owned)
                        && test_path_match(p, &read_only_watched)
                }),
            false,
        );

        if !ro_hits.is_empty() {
            return Err(fail(
                format!(
                    "STALE: uncommitted change in read_only_deps ({})",
                    ro_hits.join(", ")
                ),
                2,
            ));
        }
    }

    Ok("FRESH".to_string())
}
