use crate::error::{fail, B3Error};
use crate::fs::normalize_repo_root;
use crate::git::{assert_valid_git_rev, git_err_detail, is_hex40, new_working_tree_oid, run_git};

/// Creates a snapshot commit (or returns `HEAD` if working tree matches `HEAD^{tree}`)
/// while excluding `.b3/{ship,research-ship,autodev}` checkpoint trees.
pub fn run(repo_root_raw: &str) -> Result<String, B3Error> {
    let repo_root = normalize_repo_root(repo_root_raw)?;
    let no_env: [(&str, &str); 0] = [];
    let batch_res = run_git(
        &repo_root,
        &["rev-parse", "--quiet", "HEAD^{commit}", "HEAD^{tree}"],
        &no_env,
        None,
    )?;
    let (head_sha, head_tree) = if batch_res.exit_code == 0 {
        let txt = String::from_utf8_lossy(&batch_res.stdout);
        let mut lines = txt.lines().map(str::trim).filter(|s| !s.is_empty());
        if let (Some(c), Some(t), None) = (lines.next(), lines.next(), lines.next()) {
            if is_hex40(c) && is_hex40(t) {
                (c.to_string(), t.to_string())
            } else {
                (
                    assert_valid_git_rev(&repo_root, "HEAD", "commit", "SNAPSHOT_FAIL", "HEAD")?,
                    assert_valid_git_rev(
                        &repo_root,
                        "HEAD",
                        "tree",
                        "SNAPSHOT_FAIL",
                        "HEAD^{tree}",
                    )?,
                )
            }
        } else {
            (
                assert_valid_git_rev(&repo_root, "HEAD", "commit", "SNAPSHOT_FAIL", "HEAD")?,
                assert_valid_git_rev(&repo_root, "HEAD", "tree", "SNAPSHOT_FAIL", "HEAD^{tree}")?,
            )
        }
    } else {
        (
            assert_valid_git_rev(&repo_root, "HEAD", "commit", "SNAPSHOT_FAIL", "HEAD")?,
            assert_valid_git_rev(&repo_root, "HEAD", "tree", "SNAPSHOT_FAIL", "HEAD^{tree}")?,
        )
    };

    let cur_tree = new_working_tree_oid(&repo_root, "SNAPSHOT_FAIL", false)?;
    if cur_tree == head_tree {
        return Ok(head_sha);
    }

    let ct_res = run_git(
        &repo_root,
        &[
            "commit-tree",
            &cur_tree,
            "-p",
            &head_sha,
            "-m",
            "b3-snapshot",
        ],
        &no_env,
        None,
    )?;
    let sha = String::from_utf8_lossy(&ct_res.stdout).trim().to_string();
    if ct_res.exit_code != 0 || sha.is_empty() {
        return Err(fail(
            format!(
                "SNAPSHOT_FAIL: git commit-tree failed: {}",
                git_err_detail(&ct_res)
            ),
            1,
        ));
    }

    let type_res = run_git(&repo_root, &["cat-file", "-t", &sha], &no_env, None)?;
    let obj_type = String::from_utf8_lossy(&type_res.stdout).trim().to_string();
    if type_res.exit_code != 0 || obj_type != "commit" {
        return Err(fail(
            format!("SNAPSHOT_FAIL: invalid snapshot commit '{sha}'"),
            1,
        ));
    }

    Ok(sha)
}
