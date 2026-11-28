//! Cross-platform behavioral and security integration tests for `b3 guard merge-policy-check`
//! and `b3 pr verify`, migrating all unique coverage from `scripts/validate-merge-security.sh`
//! and `scripts/validate-research-ship.ps1`.

mod common;

use common::{
    clone_seeded_git_repo, git_in, run_b3 as raw_run_b3, run_b3_env as raw_run_b3_env, write_lf,
    write_mock_gh, TempDirGuard,
};
use std::fs;
use std::path::Path;

fn combine_output(code: i32, out: String, err: String) -> (i32, String, String) {
    let msg = if err.is_empty() {
        out
    } else if out.is_empty() {
        err
    } else {
        format!("{out}\n{err}")
    };
    (code, msg.clone(), msg)
}

fn run_b3(args: &[&str]) -> (i32, String, String) {
    let (c, out, err) = raw_run_b3(args);
    combine_output(c, out, err)
}

fn run_b3_env(
    args: &[&str],
    cwd: Option<&Path>,
    set_env: &[(&str, &str)],
    unset_env: &[&str],
) -> (i32, String, String) {
    let (c, out, err) = raw_run_b3_env(args, cwd, set_env, unset_env);
    combine_output(c, out, err)
}

const MOCK_GH_JS: &str = r#"
const fs = require('fs');
const path = require('path');
const dir = process.env.B3_TEST_GH_DIR || '';
if (!dir || !fs.existsSync(dir)) {
  process.stderr.write('HTTP 500: mock dir missing\n');
  process.exit(1);
}
const args = process.argv.slice(2);
if (!args.length || args[0] !== 'api') {
  process.stderr.write(`unexpected gh subcommand: ${args[0] || ''}\n`);
  process.exit(1);
}
let slurp = false;
let endpoint = '';
for (let i = 1; i < args.length; i++) {
  if (args[i] === '--paginate') continue;
  if (args[i] === '--slurp') { slurp = true; continue; }
  if (['-H', '--header', '-X', '--method', '-f', '-F', '--field', '--raw-field', '--jq', '-q'].includes(args[i])) {
    i++;
    continue;
  }
  endpoint = args[i];
}
const clean = endpoint.split('?')[0].replace(/^\/+/, '');
const key = clean.replace(/%2f/gi, '__').replace(/\//g, '__');
const errFile = path.join(dir, `${key}.err`);
const jsonFile = path.join(dir, `${key}.json`);
if (fs.existsSync(errFile)) {
  process.stderr.write(fs.readFileSync(errFile, 'utf8'));
  process.exit(1);
}
if (fs.existsSync(jsonFile)) {
  const raw = fs.readFileSync(jsonFile, 'utf8').trim();
  process.stdout.write(slurp ? `[${raw}]\n` : `${raw}\n`);
  process.exit(0);
}
process.stderr.write(`HTTP 404 Not Found: ${clean} (key=${key})\n`);
process.exit(1);
"#;

fn path_with_prepended(dir: &Path) -> String {
    let cur = std::env::var_os("PATH").unwrap_or_default();
    let mut parts = vec![dir.to_path_buf()];
    parts.extend(std::env::split_paths(&cur));
    std::env::join_paths(parts)
        .expect("join PATH")
        .to_string_lossy()
        .into_owned()
}

fn path_without_gh(empty_dir: &Path) -> String {
    let cur = std::env::var_os("PATH").unwrap_or_default();
    let mut kept = vec![empty_dir.to_path_buf()];
    for d in std::env::split_paths(&cur) {
        let has_gh = ["gh", "gh.exe", "gh.cmd", "gh.bat", "gh.com"]
            .iter()
            .any(|name| d.join(name).is_file());
        if !has_gh {
            kept.push(d);
            continue;
        }
        #[cfg(unix)]
        for tool in ["git", "sh", "bash"] {
            let src = d.join(tool);
            let dst = empty_dir.join(tool);
            if src.is_file() && !dst.exists() {
                std::os::unix::fs::symlink(&src, &dst).expect("symlink tool");
            }
        }
    }
    std::env::join_paths(kept)
        .expect("join PATH without gh")
        .to_string_lossy()
        .into_owned()
}

#[allow(clippy::too_many_arguments)]
fn write_premerge_fixtures(
    dir: &Path,
    slug: &str,
    pr_num: u32,
    def_br: &str,
    def_sha: &str,
    base_ref: &str,
    pr_base_sha: &str,
    live_target_sha: &str,
    head_ref: &str,
    head_sha: &str,
    ci_conc: Option<&str>,
    ci_status: &str,
    mergeable_bool: bool,
    mergeable_state: &str,
    changed_file: &str,
    head_repo: &str,
    status_state: &str,
    status_cnt: u32,
) {
    if dir.exists() {
        let _ = b3::fs::remove_dir_tree_safely(dir);
    }
    fs::create_dir_all(dir).unwrap();
    let sk = slug.replace('/', "__");
    let bk = base_ref.replace('/', "__");
    let dk = def_br.replace('/', "__");

    write_lf(
        &dir.join(format!("repos__{sk}__pulls__{pr_num}.json")),
        &format!(
            r#"{{"number":{pr_num},"state":"open","draft":false,"merged":false,"merged_at":null,"merge_commit_sha":null,"mergeable":{mergeable_bool},"mergeable_state":"{mergeable_state}","user":{{"login":"alice"}},"base":{{"ref":"{base_ref}","sha":"{pr_base_sha}","repo":{{"full_name":"{slug}","default_branch":"{def_br}"}}}},"head":{{"ref":"{head_ref}","sha":"{head_sha}","repo":{{"full_name":"{head_repo}"}}}}}}"#
        ),
    );
    write_lf(
        &dir.join(format!("repos__{sk}__branches__{bk}.json")),
        &format!(
            r#"{{"name":"{base_ref}","protected":false,"commit":{{"sha":"{live_target_sha}"}}}}"#
        ),
    );
    if def_br != base_ref {
        write_lf(
            &dir.join(format!("repos__{sk}__branches__{dk}.json")),
            &format!(r#"{{"name":"{def_br}","protected":false,"commit":{{"sha":"{def_sha}"}}}}"#),
        );
    }
    write_lf(
        &dir.join(format!("repos__{sk}__pulls__{pr_num}__files.json")),
        &format!(r#"[{{"filename":"{changed_file}","status":"modified"}}]"#),
    );
    let check_runs_json = if ci_status == "none" {
        r#"{"total_count":0,"check_runs":[]}"#.to_string()
    } else {
        let conc = ci_conc
            .map(|c| format!("\"{c}\""))
            .unwrap_or_else(|| "null".to_string());
        format!(
            r#"{{"total_count":1,"check_runs":[{{"id":500,"name":"ci/build-test","app":{{"id":15368}},"head_sha":"{head_sha}","status":"{ci_status}","conclusion":{conc}}}]}}"#
        )
    };
    write_lf(
        &dir.join(format!("repos__{sk}__commits__{head_sha}__check-runs.json")),
        &check_runs_json,
    );
    let statuses = if status_cnt > 0 {
        format!(r#"[{{"context":"ci/ext-status","state":"{status_state}"}}]"#)
    } else {
        "[]".to_string()
    };
    write_lf(
        &dir.join(format!("repos__{sk}__commits__{head_sha}__status.json")),
        &format!(
            r#"{{"sha":"{head_sha}","state":"{status_state}","total_count":{status_cnt},"statuses":{statuses}}}"#
        ),
    );
}

#[allow(clippy::too_many_arguments)]
fn write_postmerge_fixtures(
    dir: &Path,
    slug: &str,
    pr_num: u32,
    def_br: &str,
    base_ref: &str,
    head_sha: &str,
    pr_state: &str,
    pr_merged: bool,
    merge_sha: Option<&str>,
    live_target_sha: &str,
    cmp_status: Option<&str>,
    cmp_behind: i32,
    def_sha: &str,
) {
    if dir.exists() {
        let _ = b3::fs::remove_dir_tree_safely(dir);
    }
    fs::create_dir_all(dir).unwrap();
    let sk = slug.replace('/', "__");
    let bk = base_ref.replace('/', "__");
    let dk = def_br.replace('/', "__");
    let m_sha_json = merge_sha
        .map(|s| format!("\"{s}\""))
        .unwrap_or_else(|| "null".to_string());
    let m_at_json = if pr_merged {
        "\"2026-11-24T15:00:00Z\""
    } else {
        "null"
    };

    write_lf(
        &dir.join(format!("repos__{sk}__pulls__{pr_num}.json")),
        &format!(
            r#"{{"number":{pr_num},"state":"{pr_state}","merged":{pr_merged},"merged_at":{m_at_json},"merge_commit_sha":{m_sha_json},"commits":2,"base":{{"ref":"{base_ref}","sha":"{live_target_sha}","repo":{{"full_name":"{slug}","default_branch":"{def_br}"}}}},"head":{{"ref":"feat/work","sha":"{head_sha}","repo":{{"full_name":"{slug}"}}}}}}"#
        ),
    );
    write_lf(
        &dir.join(format!("repos__{sk}__branches__{bk}.json")),
        &format!(
            r#"{{"name":"{base_ref}","protected":false,"commit":{{"sha":"{live_target_sha}"}}}}"#
        ),
    );
    if def_br != base_ref {
        write_lf(
            &dir.join(format!("repos__{sk}__branches__{dk}.json")),
            &format!(r#"{{"name":"{def_br}","protected":false,"commit":{{"sha":"{def_sha}"}}}}"#),
        );
    }
    if let (Some(ms), Some(cs)) = (merge_sha, cmp_status) {
        write_lf(
            &dir.join(format!(
                "repos__{sk}__compare__{ms}...{live_target_sha}.json"
            )),
            &format!(r#"{{"status":"{cs}","behind_by":{cmp_behind},"ahead_by":0}}"#),
        );
    }
}

fn init_independent_ledger(repo: &Path, ledger_rel: &str, base_sha: &str) {
    let r_str = repo.to_str().unwrap();
    assert_eq!(
        run_b3(&[
            "guard",
            "review-ledger",
            "--repo-root",
            r_str,
            "--action",
            "init",
            "--ledger-path",
            ledger_rel,
            "--base-sha",
            base_sha,
            "--review-independence",
            "INDEPENDENT"
        ])
        .0,
        0
    );
    let txt = fs::read_to_string(repo.join(ledger_rel)).unwrap();
    for line in txt.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('|') {
            let cols: Vec<&str> = trimmed.split('|').map(str::trim).collect();
            if cols.len() >= 2 && cols[1].starts_with('U') {
                assert_eq!(
                    run_b3(&[
                        "guard",
                        "review-ledger",
                        "--repo-root",
                        r_str,
                        "--action",
                        "update",
                        "--ledger-path",
                        ledger_rel,
                        "--unit-id",
                        cols[1],
                        "--status",
                        "REVIEWED"
                    ])
                    .0,
                    0
                );
            }
        }
    }
}

fn file_uri(dir: &Path) -> String {
    let s = dir.to_string_lossy().replace('\\', "/");
    if s.starts_with('/') {
        format!("file://{s}")
    } else {
        format!("file:///{s}")
    }
}

#[test]
fn stacked_targets_base_sha_and_mock_gh_ci_gates() {
    let tmp = TempDirGuard::new("mp-targets-ci");
    let mock_bin = tmp.path.join("mock-bin");
    write_mock_gh(&mock_bin, "gh", MOCK_GH_JS);
    let mock_path = path_with_prepended(&mock_bin);

    let slug = "octo/b3-demo";
    let repo = tmp.path.join("r1");
    clone_seeded_git_repo(&repo);
    git_in(
        &repo,
        &[
            "remote",
            "add",
            "origin",
            &format!("https://github.com/{slug}.git"),
        ],
    );
    write_lf(
        &repo.join(".b3/research-policy.json"),
        r#"{"auto_merge":"authorized","protected_paths":["releases/"],"allow_protected_paths":false,"require_ci":true,"require_review":true}"#,
    );
    write_lf(&repo.join("docs/notes.md"), "# Base\n");
    git_in(&repo, &["add", "."]);
    git_in(&repo, &["commit", "-qm", "main policy"]);
    let main_sha = git_in(&repo, &["rev-parse", "HEAD"]);

    git_in(&repo, &["checkout", "-qb", "develop"]);
    write_lf(&repo.join("docs/dev.md"), "dev\n");
    git_in(&repo, &["add", "."]);
    git_in(&repo, &["commit", "-qm", "dev"]);
    let dev_sha = git_in(&repo, &["rev-parse", "HEAD"]);

    git_in(&repo, &["checkout", "-qb", "release/2026.11", &main_sha]);
    write_lf(&repo.join("docs/rel.md"), "rel\n");
    git_in(&repo, &["add", "."]);
    git_in(&repo, &["commit", "-qm", "rel"]);
    let rel_sha = git_in(&repo, &["rev-parse", "HEAD"]);

    git_in(&repo, &["checkout", "-qb", "feature/parent", &main_sha]);
    write_lf(&repo.join("docs/parent.md"), "parent\n");
    git_in(&repo, &["add", "."]);
    git_in(&repo, &["commit", "-qm", "parent"]);
    let parent_sha = git_in(&repo, &["rev-parse", "HEAD"]);

    let r_str = repo.to_str().unwrap();

    // 1. Arbitrary target branches & stacked PR
    for (t_br, t_sha, pr_id, chg) in [
        ("main", main_sha.as_str(), 11u32, "docs/pr-main.md"),
        ("develop", dev_sha.as_str(), 12u32, "docs/pr-dev.md"),
        ("release/2026.11", rel_sha.as_str(), 13u32, "docs/pr-rel.md"),
        (
            "feature/parent",
            parent_sha.as_str(),
            14u32,
            "docs/pr-stacked.md",
        ),
    ] {
        let h_br = format!("feat/pr-{pr_id}");
        git_in(&repo, &["checkout", "-qb", &h_br, t_sha]);
        write_lf(&repo.join(chg), &format!("chg {t_br}\n"));
        git_in(&repo, &["add", "--", chg]);
        git_in(&repo, &["commit", "-qm", "pr"]);
        let h_sha = git_in(&repo, &["rev-parse", "HEAD"]);
        let led = format!(".b3/research-ship/runs/pr-{pr_id}/ledger.md");
        init_independent_ledger(&repo, &led, t_sha);

        let fx = tmp.path.join(format!("fx-{pr_id}"));
        write_premerge_fixtures(
            &fx,
            slug,
            pr_id,
            "main",
            &main_sha,
            t_br,
            t_sha,
            t_sha,
            &h_br,
            &h_sha,
            Some("success"),
            "completed",
            true,
            "clean",
            chg,
            slug,
            "pending",
            0,
        );
        let pr_s = pr_id.to_string();
        let (c, out, err) = run_b3_env(
            &[
                "guard",
                "merge-policy-check",
                "--repo-root",
                r_str,
                "--pr-number",
                &pr_s,
                "--target-branch",
                t_br,
                "--base-sha",
                t_sha,
                "--ledger-path",
                &led,
            ],
            None,
            &[
                ("PATH", &mock_path),
                ("B3_TEST_GH_DIR", fx.to_str().unwrap()),
            ],
            &["B3_GH_BIN"],
        );
        assert_eq!(c, 0, "target={t_br}: {out}\n{err}");
        assert!(
            out.contains(&format!("MERGE_AUTHORIZED: mode=github pr={slug}#{pr_id} target_ref={t_br} target_sha={t_sha} head_sha={h_sha} policy_authority=main@{main_sha}")),
            "{out}"
        );
    }

    // 2. Wrong BaseSha & --base-sha HEAD fail closed
    let fx14 = tmp.path.join("fx-14");
    let (wb_c, _, wb_err) = run_b3_env(
        &[
            "guard",
            "merge-policy-check",
            "--repo-root",
            r_str,
            "--pr-number",
            "14",
            "--base-sha",
            &main_sha,
            "--ledger-path",
            ".b3/research-ship/runs/pr-14/ledger.md",
        ],
        None,
        &[
            ("PATH", &mock_path),
            ("B3_TEST_GH_DIR", fx14.to_str().unwrap()),
        ],
        &["B3_GH_BIN"],
    );
    assert_eq!(wb_c, 1);
    assert!(wb_err.contains("base_sha_mismatch"), "{wb_err}");

    let (hb_c, _, hb_err) = run_b3_env(
        &[
            "guard",
            "merge-policy-check",
            "--repo-root",
            r_str,
            "--pr-number",
            "14",
            "--base-sha",
            "HEAD",
            "--ledger-path",
            ".b3/research-ship/runs/pr-14/ledger.md",
        ],
        None,
        &[
            ("PATH", &mock_path),
            ("B3_TEST_GH_DIR", fx14.to_str().unwrap()),
        ],
        &["B3_GH_BIN"],
    );
    assert_eq!(hb_c, 1);
    assert!(hb_err.contains("base_sha_equals_head"), "{hb_err}");

    // 3. Target branch moved (live_target != pr_base, and pr_base == live_target but PR not rebased)
    git_in(&repo, &["checkout", "-q", "feature/parent"]);
    write_lf(&repo.join("docs/parent.md"), "parent moved\n");
    git_in(&repo, &["add", "--", "docs/parent.md"]);
    git_in(&repo, &["commit", "-qm", "parent moved"]);
    let parent_sha2 = git_in(&repo, &["rev-parse", "HEAD"]);
    git_in(&repo, &["checkout", "-q", "feat/pr-14"]);
    let h14_sha = git_in(&repo, &["rev-parse", "HEAD"]);

    let fx4a = tmp.path.join("fx-4a");
    write_premerge_fixtures(
        &fx4a,
        slug,
        14,
        "main",
        &main_sha,
        "feature/parent",
        &parent_sha,
        &parent_sha2,
        "feat/pr-14",
        &h14_sha,
        Some("success"),
        "completed",
        true,
        "clean",
        "docs/pr-stacked.md",
        slug,
        "pending",
        0,
    );
    let (tm1_c, _, tm1_err) = run_b3_env(
        &[
            "guard",
            "merge-policy-check",
            "--repo-root",
            r_str,
            "--pr-number",
            "14",
            "--ledger-path",
            ".b3/research-ship/runs/pr-14/ledger.md",
        ],
        None,
        &[
            ("PATH", &mock_path),
            ("B3_TEST_GH_DIR", fx4a.to_str().unwrap()),
        ],
        &["B3_GH_BIN"],
    );
    assert_eq!(tm1_c, 1);
    assert!(tm1_err.contains("target_branch_moved"), "{tm1_err}");

    let fx4b = tmp.path.join("fx-4b");
    write_premerge_fixtures(
        &fx4b,
        slug,
        14,
        "main",
        &main_sha,
        "feature/parent",
        &parent_sha2,
        &parent_sha2,
        "feat/pr-14",
        &h14_sha,
        Some("success"),
        "completed",
        true,
        "clean",
        "docs/pr-stacked.md",
        slug,
        "pending",
        0,
    );
    let (tm2_c, _, tm2_err) = run_b3_env(
        &[
            "guard",
            "merge-policy-check",
            "--repo-root",
            r_str,
            "--pr-number",
            "14",
            "--ledger-path",
            ".b3/research-ship/runs/pr-14/ledger.md",
        ],
        None,
        &[
            ("PATH", &mock_path),
            ("B3_TEST_GH_DIR", fx4b.to_str().unwrap()),
        ],
        &["B3_GH_BIN"],
    );
    assert_eq!(tm2_c, 1);
    assert!(tm2_err.contains("target_branch_moved"), "{tm2_err}");

    // 4. CI override gates, cross-app failure not masked, skipped-only vs passing+skipped, mergeable=false/dirty
    git_in(&repo, &["checkout", "-q", "feat/pr-11"]);
    let h11_sha = git_in(&repo, &["rev-parse", "HEAD"]);
    let led11 = ".b3/research-ship/runs/pr-11/ledger.md";

    let fx_fail = tmp.path.join("fx-ci-fail");
    write_premerge_fixtures(
        &fx_fail,
        slug,
        11,
        "main",
        &main_sha,
        "main",
        &main_sha,
        &main_sha,
        "feat/pr-11",
        &h11_sha,
        Some("failure"),
        "completed",
        true,
        "clean",
        "docs/pr-main.md",
        slug,
        "pending",
        0,
    );
    let (cf_c, _, cf_err) = run_b3_env(
        &[
            "guard",
            "merge-policy-check",
            "--repo-root",
            r_str,
            "--pr-number",
            "11",
            "--ci-status",
            "PASS",
            "--review-status",
            "PASS",
            "--ledger-path",
            led11,
        ],
        None,
        &[
            ("PATH", &mock_path),
            ("B3_TEST_GH_DIR", fx_fail.to_str().unwrap()),
        ],
        &["B3_GH_BIN"],
    );
    assert_eq!(cf_c, 1);
    assert!(cf_err.contains("ci_status=FAIL"), "{cf_err}");

    // Cross-app duplicate check-run failure not masked by newer passing run of same name
    let fx_xapp = tmp.path.join("fx-xapp");
    write_premerge_fixtures(
        &fx_xapp,
        slug,
        11,
        "main",
        &main_sha,
        "main",
        &main_sha,
        &main_sha,
        "feat/pr-11",
        &h11_sha,
        Some("success"),
        "completed",
        true,
        "clean",
        "docs/pr-main.md",
        slug,
        "pending",
        0,
    );
    write_lf(
        &fx_xapp.join(format!(
            "repos__{}__commits__{h11_sha}__check-runs.json",
            slug.replace('/', "__")
        )),
        &format!(
            r#"{{"total_count":2,"check_runs":[{{"id":500,"name":"ci/build-test","app":{{"id":100}},"head_sha":"{h11_sha}","status":"completed","conclusion":"failure"}},{{"id":999,"name":"ci/build-test","app":{{"id":200}},"head_sha":"{h11_sha}","status":"completed","conclusion":"success"}}]}}"#
        ),
    );
    let (xa_c, _, xa_err) = run_b3_env(
        &[
            "guard",
            "merge-policy-check",
            "--repo-root",
            r_str,
            "--pr-number",
            "11",
            "--ledger-path",
            led11,
        ],
        None,
        &[
            ("PATH", &mock_path),
            ("B3_TEST_GH_DIR", fx_xapp.to_str().unwrap()),
        ],
        &["B3_GH_BIN"],
    );
    assert_eq!(xa_c, 1);
    assert!(xa_err.contains("ci_status=FAIL"), "{xa_err}");

    // Skipped-only -> ci_status=UNKNOWN; passing + skipped -> PASS
    let fx_skip = tmp.path.join("fx-skip");
    write_premerge_fixtures(
        &fx_skip,
        slug,
        11,
        "main",
        &main_sha,
        "main",
        &main_sha,
        &main_sha,
        "feat/pr-11",
        &h11_sha,
        Some("skipped"),
        "completed",
        true,
        "clean",
        "docs/pr-main.md",
        slug,
        "pending",
        0,
    );
    let (sk_c, _, sk_err) = run_b3_env(
        &[
            "guard",
            "merge-policy-check",
            "--repo-root",
            r_str,
            "--pr-number",
            "11",
            "--ledger-path",
            led11,
        ],
        None,
        &[
            ("PATH", &mock_path),
            ("B3_TEST_GH_DIR", fx_skip.to_str().unwrap()),
        ],
        &["B3_GH_BIN"],
    );
    assert_eq!(sk_c, 1);
    assert!(sk_err.contains("ci_status=UNKNOWN"), "{sk_err}");

    write_lf(
        &fx_skip.join(format!(
            "repos__{}__commits__{h11_sha}__check-runs.json",
            slug.replace('/', "__")
        )),
        &format!(
            r#"{{"total_count":2,"check_runs":[{{"id":500,"name":"ci/lint","app":{{"id":100}},"head_sha":"{h11_sha}","status":"completed","conclusion":"skipped"}},{{"id":501,"name":"ci/test","app":{{"id":100}},"head_sha":"{h11_sha}","status":"completed","conclusion":"success"}}]}}"#
        ),
    );
    let (sk2_c, sk2_out, sk2_err) = run_b3_env(
        &[
            "guard",
            "merge-policy-check",
            "--repo-root",
            r_str,
            "--pr-number",
            "11",
            "--ledger-path",
            led11,
        ],
        None,
        &[
            ("PATH", &mock_path),
            ("B3_TEST_GH_DIR", fx_skip.to_str().unwrap()),
        ],
        &["B3_GH_BIN"],
    );
    assert_eq!(sk2_c, 0, "{sk2_out}\n{sk2_err}");

    // mergeable=false & mergeable_state=dirty
    let fx_unm = tmp.path.join("fx-unmergeable");
    write_premerge_fixtures(
        &fx_unm,
        slug,
        11,
        "main",
        &main_sha,
        "main",
        &main_sha,
        &main_sha,
        "feat/pr-11",
        &h11_sha,
        Some("success"),
        "completed",
        false,
        "dirty",
        "docs/pr-main.md",
        slug,
        "pending",
        0,
    );
    let (um_c, _, um_err) = run_b3_env(
        &[
            "guard",
            "merge-policy-check",
            "--repo-root",
            r_str,
            "--pr-number",
            "11",
            "--ledger-path",
            led11,
        ],
        None,
        &[
            ("PATH", &mock_path),
            ("B3_TEST_GH_DIR", fx_unm.to_str().unwrap()),
        ],
        &["B3_GH_BIN"],
    );
    assert_eq!(um_c, 1);
    assert!(
        um_err.contains("pr_not_mergeable(mergeable=false,state=dirty)"),
        "{um_err}"
    );

    let fx_dirty = tmp.path.join("fx-dirty");
    write_premerge_fixtures(
        &fx_dirty,
        slug,
        11,
        "main",
        &main_sha,
        "main",
        &main_sha,
        &main_sha,
        "feat/pr-11",
        &h11_sha,
        Some("success"),
        "completed",
        true,
        "dirty",
        "docs/pr-main.md",
        slug,
        "pending",
        0,
    );
    let (dr_c, _, dr_err) = run_b3_env(
        &[
            "guard",
            "merge-policy-check",
            "--repo-root",
            r_str,
            "--pr-number",
            "11",
            "--ledger-path",
            led11,
        ],
        None,
        &[
            ("PATH", &mock_path),
            ("B3_TEST_GH_DIR", fx_dirty.to_str().unwrap()),
        ],
        &["B3_GH_BIN"],
    );
    assert_eq!(dr_c, 1);
    assert!(dr_err.contains("mergeable_state=dirty"), "{dr_err}");

    // HTTP 401 / 502 / 403 / missing gh -> exit 2 PROVIDER_UNAVAILABLE
    let fx_err = tmp.path.join("fx-err");
    fs::create_dir_all(&fx_err).unwrap();
    for (pr_n, msg, token) in [
        ("401", "HTTP 401: Bad credentials\n", "github_auth_failed"),
        ("502", "HTTP 502 Bad Gateway\n", "github_http_5xx"),
        ("403", "HTTP 403 Forbidden\n", "github_access_denied"),
    ] {
        write_lf(
            &fx_err.join(format!("repos__octo__b3-demo__pulls__{pr_n}.err")),
            msg,
        );
        let (ec, _, eerr) = run_b3_env(
            &[
                "guard",
                "merge-policy-check",
                "--repo-root",
                r_str,
                "--pr-number",
                pr_n,
                "--ledger-path",
                led11,
            ],
            None,
            &[
                ("PATH", &mock_path),
                ("B3_TEST_GH_DIR", fx_err.to_str().unwrap()),
            ],
            &["B3_GH_BIN"],
        );
        assert_eq!(ec, 2, "HTTP {pr_n}: {eerr}");
        assert!(
            eerr.contains("PROVIDER_UNAVAILABLE:") && eerr.contains(token),
            "{eerr}"
        );
    }

    let empty_gh_dir = tmp.path.join("nogh-dir");
    fs::create_dir_all(&empty_gh_dir).unwrap();
    let nogh_path = path_without_gh(&empty_gh_dir);
    let (ng_c, _, ng_err) = run_b3_env(
        &[
            "guard",
            "merge-policy-check",
            "--repo-root",
            r_str,
            "--pr-number",
            "11",
            "--ledger-path",
            led11,
        ],
        None,
        &[("PATH", &nogh_path)],
        &["B3_GH_BIN"],
    );
    assert_eq!(ng_c, 2, "{ng_err}");
    assert!(
        ng_err.contains("PROVIDER_UNAVAILABLE:") && ng_err.contains("gh_cli_unavailable"),
        "{ng_err}"
    );

    // 5. Credentialed + mixed-case HTTPS origin allowed without leaking secret
    git_in(
        &repo,
        &[
            "remote",
            "set-url",
            "origin",
            "https://x-access-token:ghs_secret_tok_999@GitHub.com/octo/b3-demo.git",
        ],
    );
    let fx11 = tmp.path.join("fx-11");
    let (cr_c, cr_out, cr_err) = run_b3_env(
        &[
            "guard",
            "merge-policy-check",
            "--repo-root",
            r_str,
            "--pr-number",
            "11",
            "--ledger-path",
            led11,
        ],
        None,
        &[
            ("PATH", &mock_path),
            ("B3_TEST_GH_DIR", fx11.to_str().unwrap()),
        ],
        &["B3_GH_BIN"],
    );
    assert_eq!(cr_c, 0, "{cr_out}\n{cr_err}");
    assert!(!cr_out.contains("ghs_secret_tok_999") && !cr_err.contains("ghs_secret_tok_999"));

    // upstream-only without --repo fails closed (origin_remote_missing)
    git_in(&repo, &["remote", "remove", "origin"]);
    git_in(
        &repo,
        &[
            "remote",
            "add",
            "upstream",
            "https://github.com/octo/b3-demo.git",
        ],
    );
    let (up_c, _, up_err) = run_b3_env(
        &[
            "guard",
            "merge-policy-check",
            "--repo-root",
            r_str,
            "--pr-number",
            "11",
            "--ledger-path",
            led11,
        ],
        None,
        &[
            ("PATH", &mock_path),
            ("B3_TEST_GH_DIR", fx11.to_str().unwrap()),
        ],
        &["B3_GH_BIN"],
    );
    assert_eq!(up_c, 1);
    assert!(up_err.contains("origin_remote_missing"), "{up_err}");

    // Fork PR blocked (cross_repo_head_pr) & repo flag mismatch (cross_repo_mismatch)
    git_in(
        &repo,
        &[
            "remote",
            "add",
            "origin",
            "https://github.com/octo/b3-demo.git",
        ],
    );
    let (rm_c, _, rm_err) = run_b3_env(
        &[
            "guard",
            "merge-policy-check",
            "--repo-root",
            r_str,
            "--pr-number",
            "11",
            "--repo",
            "evil/other",
            "--ledger-path",
            led11,
        ],
        None,
        &[
            ("PATH", &mock_path),
            ("B3_TEST_GH_DIR", fx11.to_str().unwrap()),
        ],
        &["B3_GH_BIN"],
    );
    assert_eq!(rm_c, 1);
    assert!(rm_err.contains("repo_mismatch"), "{rm_err}");

    let fx_fork = tmp.path.join("fx-fork");
    write_premerge_fixtures(
        &fx_fork,
        slug,
        11,
        "main",
        &main_sha,
        "main",
        &main_sha,
        &main_sha,
        "feat/pr-11",
        &h11_sha,
        Some("success"),
        "completed",
        true,
        "clean",
        "docs/pr-main.md",
        "forkuser/b3-demo",
        "pending",
        0,
    );
    let (fk_c, _, fk_err) = run_b3_env(
        &[
            "guard",
            "merge-policy-check",
            "--repo-root",
            r_str,
            "--pr-number",
            "11",
            "--ledger-path",
            led11,
        ],
        None,
        &[
            ("PATH", &mock_path),
            ("B3_TEST_GH_DIR", fx_fork.to_str().unwrap()),
        ],
        &["B3_GH_BIN"],
    );
    assert_eq!(fk_c, 1);
    assert!(fk_err.contains("cross_repo_head_pr"), "{fk_err}");

    // allowed_target_branches glob check: develop blocked, release/* allowed
    let r_glob = tmp.path.join("r-glob");
    clone_seeded_git_repo(&r_glob);
    git_in(
        &r_glob,
        &[
            "remote",
            "add",
            "origin",
            "https://github.com/octo/b3-demo.git",
        ],
    );
    write_lf(
        &r_glob.join(".b3/research-policy.json"),
        r#"{"auto_merge":"authorized","protected_paths":[],"allow_protected_paths":false,"require_ci":true,"require_review":false,"allowed_target_branches":["main","release/*"]}"#,
    );
    git_in(&r_glob, &["add", "."]);
    git_in(&r_glob, &["commit", "-qm", "glob policy"]);
    let gm_sha = git_in(&r_glob, &["rev-parse", "HEAD"]);
    git_in(&r_glob, &["checkout", "-qb", "develop", &gm_sha]);
    git_in(&r_glob, &["branch", "release/2026.11", &gm_sha]);
    git_in(&r_glob, &["checkout", "-qb", "feat/glob", &gm_sha]);
    write_lf(&r_glob.join("docs/x.md"), "x\n");
    git_in(&r_glob, &["add", "."]);
    git_in(&r_glob, &["commit", "-qm", "x"]);
    let gh_sha = git_in(&r_glob, &["rev-parse", "HEAD"]);
    init_independent_ledger(&r_glob, ".b3/ship/l.md", &gm_sha);

    let fx_g1 = tmp.path.join("fx-g1");
    write_premerge_fixtures(
        &fx_g1,
        slug,
        132,
        "main",
        &gm_sha,
        "develop",
        &gm_sha,
        &gm_sha,
        "feat/glob",
        &gh_sha,
        Some("success"),
        "completed",
        true,
        "clean",
        "docs/x.md",
        slug,
        "pending",
        0,
    );
    let (g1_c, _, g1_err) = run_b3_env(
        &[
            "guard",
            "merge-policy-check",
            "--repo-root",
            r_glob.to_str().unwrap(),
            "--pr-number",
            "132",
            "--ledger-path",
            ".b3/ship/l.md",
        ],
        None,
        &[
            ("PATH", &mock_path),
            ("B3_TEST_GH_DIR", fx_g1.to_str().unwrap()),
        ],
        &["B3_GH_BIN"],
    );
    assert_eq!(g1_c, 1);
    assert!(
        g1_err.contains("target_branch_not_allowed(develop)"),
        "{g1_err}"
    );

    let fx_g2 = tmp.path.join("fx-g2");
    write_premerge_fixtures(
        &fx_g2,
        slug,
        133,
        "main",
        &gm_sha,
        "release/2026.11",
        &gm_sha,
        &gm_sha,
        "feat/glob",
        &gh_sha,
        Some("success"),
        "completed",
        true,
        "clean",
        "docs/x.md",
        slug,
        "pending",
        0,
    );
    let (g2_c, g2_out, g2_err) = run_b3_env(
        &[
            "guard",
            "merge-policy-check",
            "--repo-root",
            r_glob.to_str().unwrap(),
            "--pr-number",
            "133",
            "--ledger-path",
            ".b3/ship/l.md",
        ],
        None,
        &[
            ("PATH", &mock_path),
            ("B3_TEST_GH_DIR", fx_g2.to_str().unwrap()),
        ],
        &["B3_GH_BIN"],
    );
    assert_eq!(g2_c, 0, "{g2_out}\n{g2_err}");
}

#[test]
fn s001_trunk_authority_tamper_and_protected_path_hardening() {
    let tmp = TempDirGuard::new("mp-s001-prot");
    let mock_bin = tmp.path.join("mock-bin");
    write_mock_gh(&mock_bin, "gh", MOCK_GH_JS);
    let mock_path = path_with_prepended(&mock_bin);
    let slug = "octo/b3-sec";

    // 1. S001 GitHub & stacked-parent policy tamper
    let repo = tmp.path.join("r5");
    clone_seeded_git_repo(&repo);
    git_in(
        &repo,
        &[
            "remote",
            "add",
            "origin",
            &format!("https://github.com/{slug}.git"),
        ],
    );
    write_lf(
        &repo.join(".b3/research-policy.json"),
        r#"{"auto_merge":"disabled","protected_paths":["releases/"],"allow_protected_paths":false,"require_ci":true,"require_review":true}"#,
    );
    write_lf(&repo.join("docs/a.md"), "# Base\n");
    git_in(&repo, &["add", "."]);
    git_in(&repo, &["commit", "-qm", "main disabled"]);
    let r5_main = git_in(&repo, &["rev-parse", "HEAD"]);

    git_in(&repo, &["checkout", "-qb", "feat/self-auth"]);
    write_lf(
        &repo.join(".b3/research-policy.json"),
        r#"{"auto_merge":"authorized","protected_paths":[],"allow_protected_paths":true,"require_ci":false,"require_review":false}"#,
    );
    write_lf(&repo.join("docs/b.md"), "ok\n");
    git_in(&repo, &["add", "."]);
    git_in(&repo, &["commit", "-qm", "self-auth"]);
    let r5_head = git_in(&repo, &["rev-parse", "HEAD"]);
    let r_str = repo.to_str().unwrap();

    let fx5a = tmp.path.join("fx-5a");
    write_premerge_fixtures(
        &fx5a,
        slug,
        51,
        "main",
        &r5_main,
        "main",
        &r5_main,
        &r5_main,
        "feat/self-auth",
        &r5_head,
        Some("success"),
        "completed",
        true,
        "clean",
        ".b3/research-policy.json",
        slug,
        "pending",
        0,
    );
    let (c5a, _, e5a) = run_b3_env(
        &[
            "guard",
            "merge-policy-check",
            "--repo-root",
            r_str,
            "--pr-number",
            "51",
            "--ci-status",
            "PASS",
            "--review-status",
            "PASS",
        ],
        None,
        &[
            ("PATH", &mock_path),
            ("B3_TEST_GH_DIR", fx5a.to_str().unwrap()),
        ],
        &["B3_GH_BIN"],
    );
    assert_eq!(c5a, 1);
    assert!(
        e5a.contains("MERGE_BLOCKED: policy_modified_in_pr"),
        "{e5a}"
    );

    // Stacked parent policy tamper
    git_in(&repo, &["checkout", "-qb", "feat/stacked-child", &r5_head]);
    write_lf(&repo.join("docs/child.md"), "child\n");
    git_in(&repo, &["add", "."]);
    git_in(&repo, &["commit", "-qm", "child"]);
    let r5_child = git_in(&repo, &["rev-parse", "HEAD"]);
    let fx5b = tmp.path.join("fx-5b");
    write_premerge_fixtures(
        &fx5b,
        slug,
        52,
        "main",
        &r5_main,
        "feat/self-auth",
        &r5_head,
        &r5_head,
        "feat/stacked-child",
        &r5_child,
        Some("success"),
        "completed",
        true,
        "clean",
        "docs/child.md",
        slug,
        "pending",
        0,
    );
    let (c5b, _, e5b) = run_b3_env(
        &[
            "guard",
            "merge-policy-check",
            "--repo-root",
            r_str,
            "--pr-number",
            "52",
            "--base-sha",
            &r5_head,
        ],
        None,
        &[
            ("PATH", &mock_path),
            ("B3_TEST_GH_DIR", fx5b.to_str().unwrap()),
        ],
        &["B3_GH_BIN"],
    );
    assert_eq!(c5b, 1);
    assert!(
        e5b.contains("MERGE_BLOCKED: target_branch_modified_policy"),
        "{e5b}"
    );

    // 2. Missing trunk policy + feature branch injects authorized policy + local staged/WT tamper
    let r5c = tmp.path.join("r5c");
    clone_seeded_git_repo(&r5c);
    let r5c_main = git_in(&r5c, &["rev-parse", "HEAD"]);
    git_in(&r5c, &["checkout", "-qb", "feat/inject-pol"]);
    write_lf(
        &r5c.join(".b3/research-policy.json"),
        r#"{"auto_merge":"authorized","require_ci":false}"#,
    );
    git_in(&r5c, &["add", "."]);
    git_in(&r5c, &["commit", "-qm", "inject policy"]);
    init_independent_ledger(&r5c, ".b3/ship/l5c.md", &r5c_main);
    let (c5c, _, e5c) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        r5c.to_str().unwrap(),
        "--authority-ref",
        "main",
        "--target-ref",
        "main",
        "--ledger-path",
        ".b3/ship/l5c.md",
    ]);
    assert_eq!(c5c, 1);
    assert!(
        e5c.contains("MERGE_BLOCKED: policy_not_in_authority"),
        "{e5c}"
    );

    // Local repo with committed disabled policy on main + staged tamper on main
    let r5d = tmp.path.join("r5d");
    clone_seeded_git_repo(&r5d);
    write_lf(
        &r5d.join(".b3/research-policy.json"),
        r#"{"auto_merge":"disabled","protected_paths":["releases/"],"allow_protected_paths":false,"require_ci":false,"require_review":true}"#,
    );
    git_in(&r5d, &["add", "."]);
    git_in(&r5d, &["commit", "-qm", "main disabled"]);
    let r5d_main = git_in(&r5d, &["rev-parse", "HEAD"]);
    git_in(&r5d, &["checkout", "-qb", "feat/tamper-loc"]);
    write_lf(
        &r5d.join(".b3/research-policy.json"),
        r#"{"auto_merge":"authorized","require_ci":false,"require_review":true}"#,
    );
    git_in(&r5d, &["add", ".b3/research-policy.json"]);
    init_independent_ledger(&r5d, ".b3/ship/l5d.md", &r5d_main);
    let (c5d, _, e5d) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        r5d.to_str().unwrap(),
        "--authority-ref",
        "main",
        "--target-ref",
        "main",
        "--ledger-path",
        ".b3/ship/l5d.md",
    ]);
    assert_eq!(c5d, 1);
    assert!(
        e5d.contains("MERGE_BLOCKED: policy_modified_in_pr"),
        "{e5d}"
    );

    // 3. --policy-path override blocked + protected_paths: ["./"] + JSON type/injection checks
    let r13 = tmp.path.join("r13");
    clone_seeded_git_repo(&r13);
    git_in(
        &r13,
        &[
            "remote",
            "add",
            "origin",
            &format!("https://github.com/{slug}.git"),
        ],
    );
    write_lf(
        &r13.join(".b3/research-policy.json"),
        r#"{"auto_merge":"disabled","protected_paths":[],"allow_protected_paths":false,"require_ci":true,"require_review":true}"#,
    );
    write_lf(
        &r13.join("tests/fake-auth-policy.json"),
        r#"{"auto_merge":"authorized","protected_paths":[],"allow_protected_paths":true,"require_ci":false,"require_review":false}"#,
    );
    git_in(&r13, &["add", "."]);
    git_in(&r13, &["commit", "-qm", "init r13"]);
    let r13_main = git_in(&r13, &["rev-parse", "HEAD"]);
    git_in(&r13, &["checkout", "-qb", "feat/pol-sub"]);
    write_lf(&r13.join("docs/work.md"), "work\n");
    git_in(&r13, &["add", "."]);
    git_in(&r13, &["commit", "-qm", "work"]);
    let r13_head = git_in(&r13, &["rev-parse", "HEAD"]);
    init_independent_ledger(&r13, ".b3/ship/l13.md", &r13_main);
    let fx13 = tmp.path.join("fx-13");
    write_premerge_fixtures(
        &fx13,
        slug,
        130,
        "main",
        &r13_main,
        "main",
        &r13_main,
        &r13_main,
        "feat/pol-sub",
        &r13_head,
        Some("success"),
        "completed",
        true,
        "clean",
        "docs/work.md",
        slug,
        "pending",
        0,
    );
    let (po_c, _, po_err) = run_b3_env(
        &[
            "guard",
            "merge-policy-check",
            "--repo-root",
            r13.to_str().unwrap(),
            "--pr-number",
            "130",
            "--policy-path",
            "tests/fake-auth-policy.json",
            "--ledger-path",
            ".b3/ship/l13.md",
        ],
        None,
        &[
            ("PATH", &mock_path),
            ("B3_TEST_GH_DIR", fx13.to_str().unwrap()),
        ],
        &["B3_GH_BIN"],
    );
    assert_eq!(po_c, 1);
    assert!(
        po_err.contains("policy_path_override_not_allowed"),
        "{po_err}"
    );

    write_lf(
        &r13.join(".b3/dot-slash.json"),
        r#"{"auto_merge":"disabled","protected_paths":["./"],"allow_protected_paths":false,"require_ci":true,"require_review":true}"#,
    );
    let (ds_c, _, ds_err) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        r13.to_str().unwrap(),
        "--policy-path",
        ".b3/dot-slash.json",
        "--pr-state",
        "OPEN",
        "--ci-status",
        "PASS",
        "--review-status",
        "PASS",
        "--changed-paths",
        "docs/work.md",
    ]);
    assert_eq!(ds_c, 1);
    assert!(ds_err.contains("protected_paths=docs/work.md"), "{ds_err}");

    // 4. R002/H-04: protected-path traversal, ./, core.ignorecase, rename out of protected dir, Unicode/bracket/space
    let r_prot = tmp.path.join("r-prot");
    clone_seeded_git_repo(&r_prot);
    write_lf(
        &r_prot.join(".b3/research-policy.json"),
        r#"{"auto_merge":"authorized","protected_paths":["releases/"],"allow_protected_paths":false,"require_ci":true,"require_review":true}"#,
    );
    write_lf(&r_prot.join("releases/v1.json"), "keep\n");
    git_in(&r_prot, &["add", "."]);
    git_in(&r_prot, &["commit", "-qm", "base"]);
    let rp_main = git_in(&r_prot, &["rev-parse", "HEAD"]);
    let rp_str = r_prot.to_str().unwrap();

    // Traversal & dot segment
    for bad_cp in ["docs/../releases/v3.json", "releases/./v3.json"] {
        let (c, _, err) = run_b3(&[
            "guard",
            "merge-policy-check",
            "--repo-root",
            rp_str,
            "--pr-state",
            "OPEN",
            "--ci-status",
            "PASS",
            "--review-status",
            "PASS",
            "--changed-paths",
            bad_cp,
        ]);
        assert_eq!(c, 1);
        assert!(err.contains("invalid_changed_path"), "{bad_cp}: {err}");
    }

    // core.ignorecase=false vs true with Releases/v1.json (dedicated repo so NTFS doesn't inherit lowercase `releases/`)
    let r_cs = tmp.path.join("r-prot-cs");
    clone_seeded_git_repo(&r_cs);
    write_lf(
        &r_cs.join(".b3/research-policy.json"),
        r#"{"auto_merge":"authorized","protected_paths":["releases/"],"allow_protected_paths":false,"require_ci":true,"require_review":true}"#,
    );
    git_in(&r_cs, &["add", "."]);
    git_in(&r_cs, &["commit", "-qm", "cs base"]);
    let cs_main = git_in(&r_cs, &["rev-parse", "HEAD"]);
    let cs_str = r_cs.to_str().unwrap();
    git_in(&r_cs, &["config", "core.ignorecase", "false"]);
    git_in(&r_cs, &["checkout", "-qb", "feat/cs", &cs_main]);
    write_lf(&r_cs.join("Releases/v1.json"), "{\"v\":1}\n");
    git_in(&r_cs, &["add", "."]);
    git_in(&r_cs, &["commit", "-qm", "cs upper"]);
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            cs_str,
            "--verify-cmd",
            "echo cs",
            "--receipt-path",
            ".b3/ship/cs.verify",
        ])
        .0,
        0
    );
    init_independent_ledger(&r_cs, ".b3/ship/cs.md", &cs_main);
    let (cs_off_c, cs_off_out, cs_off_err) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        cs_str,
        "--receipt-path",
        ".b3/ship/cs.verify",
        "--ledger-path",
        ".b3/ship/cs.md",
    ]);
    assert_eq!(
        cs_off_c, 0,
        "ignorecase=false should allow Releases/v1.json: {cs_off_out}\n{cs_off_err}"
    );

    git_in(&r_cs, &["config", "core.ignorecase", "true"]);
    let (cs_on_c, _, cs_on_err) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        cs_str,
        "--receipt-path",
        ".b3/ship/cs.verify",
        "--ledger-path",
        ".b3/ship/cs.md",
    ]);
    assert_eq!(cs_on_c, 1);
    assert!(
        cs_on_err.contains("protected_paths=Releases/v1.json"),
        "{cs_on_err}"
    );

    // Rename out of protected dir: git mv releases/v1.json -> docs/moved name [2].md
    git_in(&r_prot, &["checkout", "-qb", "feat/ren", &rp_main]);
    git_in(
        &r_prot,
        &["mv", "releases/v1.json", "docs/moved name [2].md"],
    );
    git_in(&r_prot, &["commit", "-qm", "rename out"]);
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            rp_str,
            "--verify-cmd",
            "echo ren",
            "--receipt-path",
            ".b3/ship/ren.verify",
        ])
        .0,
        0
    );
    init_independent_ledger(&r_prot, ".b3/ship/ren.md", &rp_main);
    let (ren_c, _, ren_err) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        rp_str,
        "--receipt-path",
        ".b3/ship/ren.verify",
        "--ledger-path",
        ".b3/ship/ren.md",
    ]);
    assert_eq!(ren_c, 1);
    assert!(
        ren_err.contains("protected_paths=releases/v1.json"),
        "{ren_err}"
    );

    // Unicode/bracket/space protected vs clean path
    git_in(&r_prot, &["checkout", "-qb", "feat/uni-prot", &rp_main]);
    write_lf(
        &r_prot.join("releases/tài liệu [v1] copy.json"),
        "{\"u\":1}\n",
    );
    git_in(&r_prot, &["add", "."]);
    git_in(&r_prot, &["commit", "-qm", "uni prot"]);
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            rp_str,
            "--verify-cmd",
            "echo up",
            "--receipt-path",
            ".b3/ship/up.verify",
        ])
        .0,
        0
    );
    init_independent_ledger(&r_prot, ".b3/ship/up.md", &rp_main);
    let (up_c, _, up_err) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        rp_str,
        "--receipt-path",
        ".b3/ship/up.verify",
        "--ledger-path",
        ".b3/ship/up.md",
    ]);
    assert_eq!(up_c, 1);
    assert!(
        up_err.contains("protected_paths=releases/tài liệu [v1] copy.json"),
        "{up_err}"
    );

    git_in(&r_prot, &["checkout", "-qb", "feat/uni-clean", &rp_main]);
    write_lf(&r_prot.join("docs/ghi chú [ok].md"), "ok\n");
    git_in(&r_prot, &["add", "."]);
    git_in(&r_prot, &["commit", "-qm", "uni clean"]);
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            rp_str,
            "--verify-cmd",
            "echo uc",
            "--receipt-path",
            ".b3/ship/uc.verify",
        ])
        .0,
        0
    );
    init_independent_ledger(&r_prot, ".b3/ship/uc.md", &rp_main);
    let (uc_c, uc_out, uc_err) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        rp_str,
        "--receipt-path",
        ".b3/ship/uc.verify",
        "--ledger-path",
        ".b3/ship/uc.md",
    ]);
    assert_eq!(uc_c, 0, "{uc_out}\n{uc_err}");
    assert!(uc_out.contains("MERGE_AUTHORIZED: mode=local"), "{uc_out}");
}

#[test]
fn post_merge_integrity_and_r003_live_bare_remote() {
    let tmp = TempDirGuard::new("mp-postmerge-r003");
    let mock_bin = tmp.path.join("mock-bin");
    write_mock_gh(&mock_bin, "gh", MOCK_GH_JS);
    let mock_path = path_with_prepended(&mock_bin);
    let slug = "octo/b3-pm";

    // 1. GitHub & local post-merge integrity (merge commit, squash, rebase, forged MERGED, diverged, S002 ancestry, B3_TEST_FORCE_POST_MERGE_ELIGIBLE)
    let r9 = tmp.path.join("r9");
    clone_seeded_git_repo(&r9);
    git_in(
        &r9,
        &[
            "remote",
            "add",
            "origin",
            &format!("https://github.com/{slug}.git"),
        ],
    );
    write_lf(&r9.join("docs/main.md"), "# Main v1\n");
    git_in(&r9, &["add", "."]);
    git_in(&r9, &["commit", "-qm", "main v1"]);
    let r9_main0 = git_in(&r9, &["rev-parse", "HEAD"]);

    // (A) Merge commit into main
    git_in(&r9, &["checkout", "-qb", "feat/mc"]);
    write_lf(&r9.join("docs/mc.md"), "mc\n");
    git_in(&r9, &["add", "."]);
    git_in(&r9, &["commit", "-qm", "mc work"]);
    let mc_head = git_in(&r9, &["rev-parse", "HEAD"]);
    git_in(&r9, &["checkout", "-q", "main"]);
    git_in(&r9, &["merge", "--no-ff", "-qm", "Merge PR #91", "feat/mc"]);
    let mc_merge_sha = git_in(&r9, &["rev-parse", "HEAD"]);

    // (B) Squash merge into develop
    git_in(&r9, &["checkout", "-qb", "develop", &r9_main0]);
    write_lf(&r9.join("docs/dev.md"), "dev base\n");
    git_in(&r9, &["add", "."]);
    git_in(&r9, &["commit", "-qm", "dev base"]);
    let dev_base = git_in(&r9, &["rev-parse", "HEAD"]);
    git_in(&r9, &["checkout", "-qb", "feat/sq", &dev_base]);
    write_lf(&r9.join("docs/sq.md"), "sq1\nsq2\n");
    git_in(&r9, &["add", "."]);
    git_in(&r9, &["commit", "-qm", "sq work"]);
    let sq_head = git_in(&r9, &["rev-parse", "HEAD"]);
    git_in(&r9, &["checkout", "-q", "develop"]);
    git_in(&r9, &["merge", "--squash", "-q", "feat/sq"]);
    git_in(&r9, &["commit", "-qm", "feat: squashed (#92)"]);
    let sq_merge_sha = git_in(&r9, &["rev-parse", "HEAD"]);

    // (C) Rebase merge into feature/parent
    git_in(&r9, &["checkout", "-qb", "feature/parent", &r9_main0]);
    write_lf(&r9.join("docs/p.md"), "p1\n");
    git_in(&r9, &["add", "."]);
    git_in(&r9, &["commit", "-qm", "p1"]);
    let p_base = git_in(&r9, &["rev-parse", "HEAD"]);
    git_in(&r9, &["checkout", "-qb", "feat/rb", &p_base]);
    write_lf(&r9.join("docs/rb.md"), "rb1\n");
    git_in(&r9, &["add", "."]);
    git_in(&r9, &["commit", "-qm", "rb1"]);
    let rb_head = git_in(&r9, &["rev-parse", "HEAD"]);
    git_in(&r9, &["checkout", "-q", "feature/parent"]);
    write_lf(&r9.join("docs/p.md"), "p1\np2\n");
    git_in(&r9, &["add", "."]);
    git_in(&r9, &["commit", "-qm", "p2"]);
    git_in(&r9, &["cherry-pick", &rb_head]);
    let rb_merge_sha = git_in(&r9, &["rev-parse", "HEAD"]);

    let r9_str = r9.to_str().unwrap();

    for (id, pr_n, br, h_sha, m_sha, kind) in [
        (
            "mc",
            "91",
            "main",
            mc_head.as_str(),
            mc_merge_sha.as_str(),
            "merge_commit",
        ),
        (
            "sq",
            "92",
            "develop",
            sq_head.as_str(),
            sq_merge_sha.as_str(),
            "squash_or_rebase",
        ),
        (
            "rb",
            "93",
            "feature/parent",
            rb_head.as_str(),
            rb_merge_sha.as_str(),
            "squash_or_rebase",
        ),
    ] {
        let fx = tmp.path.join(format!("fx-pm-{id}"));
        write_postmerge_fixtures(
            &fx,
            slug,
            pr_n.parse().unwrap(),
            "main",
            br,
            h_sha,
            "closed",
            true,
            Some(m_sha),
            m_sha,
            Some("identical"),
            0,
            &mc_merge_sha,
        );
        let (c, out, err) = run_b3_env(
            &[
                "guard",
                "merge-policy-check",
                "--repo-root",
                r9_str,
                "--post-merge",
                "--pr-number",
                pr_n,
                "--main-ref",
                br,
                "--merged-sha",
                m_sha,
            ],
            None,
            &[
                ("PATH", &mock_path),
                ("B3_TEST_GH_DIR", fx.to_str().unwrap()),
            ],
            &["B3_GH_BIN"],
        );
        assert_eq!(c, 0, "pm-{id}: {out}\n{err}");
        assert!(out.contains(&format!("merge_kind={kind}")), "{out}");
    }

    // Forged MERGED on open PR, missing merge_commit_sha, diverged remote, B3_TEST_FORCE_POST_MERGE_ELIGIBLE=1
    let fx_open = tmp.path.join("fx-pm-open");
    write_postmerge_fixtures(
        &fx_open,
        slug,
        94,
        "main",
        "main",
        &mc_head,
        "open",
        false,
        None,
        &mc_merge_sha,
        None,
        -1,
        &mc_merge_sha,
    );
    let (fo_c, _, fo_err) = run_b3_env(
        &[
            "guard",
            "merge-policy-check",
            "--repo-root",
            r9_str,
            "--post-merge",
            "--pr-state",
            "MERGED",
            "--pr-number",
            "94",
            "--main-ref",
            "main",
            "--merged-sha",
            &mc_merge_sha,
        ],
        None,
        &[
            ("PATH", &mock_path),
            ("B3_TEST_GH_DIR", fx_open.to_str().unwrap()),
            ("B3_TEST_FORCE_POST_MERGE_ELIGIBLE", "1"),
        ],
        &["B3_GH_BIN"],
    );
    assert_eq!(fo_c, 1);
    assert!(
        fo_err.contains("pr_not_merged(state=OPEN,merged=false)"),
        "{fo_err}"
    );

    let fx_nomerge = tmp.path.join("fx-pm-nomerge");
    write_postmerge_fixtures(
        &fx_nomerge,
        slug,
        95,
        "main",
        "main",
        &mc_head,
        "closed",
        true,
        None,
        &mc_merge_sha,
        None,
        -1,
        &mc_merge_sha,
    );
    let (nm_c, _, nm_err) = run_b3_env(
        &[
            "guard",
            "merge-policy-check",
            "--repo-root",
            r9_str,
            "--post-merge",
            "--pr-number",
            "95",
            "--main-ref",
            "main",
        ],
        None,
        &[
            ("PATH", &mock_path),
            ("B3_TEST_GH_DIR", fx_nomerge.to_str().unwrap()),
        ],
        &["B3_GH_BIN"],
    );
    assert_eq!(nm_c, 1);
    assert!(nm_err.contains("missing_merge_commit_sha"), "{nm_err}");

    let fx_div = tmp.path.join("fx-pm-div");
    write_postmerge_fixtures(
        &fx_div,
        slug,
        91,
        "main",
        "main",
        &mc_head,
        "closed",
        true,
        Some(&mc_merge_sha),
        &r9_main0,
        Some("diverged"),
        1,
        &r9_main0,
    );
    let (dv_c, _, dv_err) = run_b3_env(
        &[
            "guard",
            "merge-policy-check",
            "--repo-root",
            r9_str,
            "--post-merge",
            "--pr-number",
            "91",
            "--main-ref",
            "main",
        ],
        None,
        &[
            ("PATH", &mock_path),
            ("B3_TEST_GH_DIR", fx_div.to_str().unwrap()),
        ],
        &["B3_GH_BIN"],
    );
    assert_eq!(dv_c, 1);
    assert!(
        dv_err.contains("merge_commit_not_in_remote_target"),
        "{dv_err}"
    );

    // Local post-merge S002: merge_commit, fast_forward, sha_not_in_target, merge_commit_head_mismatch
    let r9l = tmp.path.join("r9-local");
    clone_seeded_git_repo(&r9l);
    git_in(&r9l, &["checkout", "-qb", "feat/loc-mc"]);
    write_lf(&r9l.join("docs/mc.md"), "mc\n");
    git_in(&r9l, &["add", "."]);
    git_in(&r9l, &["commit", "-qm", "loc mc"]);
    let l_mc_head = git_in(&r9l, &["rev-parse", "HEAD"]);
    git_in(&r9l, &["checkout", "-q", "main"]);
    git_in(
        &r9l,
        &["merge", "--no-ff", "-qm", "local mc", "feat/loc-mc"],
    );
    let l_mc_merge = git_in(&r9l, &["rev-parse", "HEAD"]);
    let r9l_str = r9l.to_str().unwrap();

    let (lmc_c, lmc_out, _) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        r9l_str,
        "--post-merge",
        "--target-ref",
        "main",
        "--head-sha",
        &l_mc_head,
        "--merged-sha",
        &l_mc_merge,
    ]);
    assert_eq!(lmc_c, 0);
    assert!(lmc_out.contains("merge_kind=merge_commit"), "{lmc_out}");

    git_in(&r9l, &["checkout", "-qb", "feat/loc-ff"]);
    write_lf(&r9l.join("docs/ff.md"), "ff\n");
    git_in(&r9l, &["add", "."]);
    git_in(&r9l, &["commit", "-qm", "loc ff"]);
    let l_ff_head = git_in(&r9l, &["rev-parse", "HEAD"]);
    git_in(&r9l, &["checkout", "-q", "main"]);
    git_in(&r9l, &["merge", "--ff-only", "-q", "feat/loc-ff"]);
    let (lff_c, lff_out, _) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        r9l_str,
        "--post-merge",
        "--target-ref",
        "main",
        "--head-sha",
        &l_ff_head,
        "--merged-sha",
        &l_ff_head,
    ]);
    assert_eq!(lff_c, 0);
    assert!(lff_out.contains("merge_kind=fast_forward"), "{lff_out}");

    git_in(&r9l, &["checkout", "-qb", "feat/unmerged"]);
    write_lf(&r9l.join("docs/unmerged.md"), "u\n");
    git_in(&r9l, &["add", "."]);
    git_in(&r9l, &["commit", "-qm", "unmerged"]);
    let l_unmerged = git_in(&r9l, &["rev-parse", "HEAD"]);
    git_in(&r9l, &["checkout", "-q", "main"]);
    let (u1_c, _, u1_err) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        r9l_str,
        "--post-merge",
        "--target-ref",
        "main",
        "--head-sha",
        &l_unmerged,
        "--merged-sha",
        &l_unmerged,
    ]);
    assert_eq!(u1_c, 1);
    assert!(u1_err.contains("sha_not_in_target"), "{u1_err}");

    let (u2_c, _, u2_err) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        r9l_str,
        "--post-merge",
        "--target-ref",
        "main",
        "--head-sha",
        &l_unmerged,
        "--merged-sha",
        &l_mc_merge,
    ]);
    assert_eq!(u2_c, 1);
    assert!(u2_err.contains("merge_commit_head_mismatch"), "{u2_err}");

    // 2. R003 live file:// bare remote ls-remote freshness + stale_remote_ref / stale_remote_target_ref / stale_remote_authority_ref
    let bare = tmp.path.join("r14-bare.git");
    fs::create_dir_all(&bare).unwrap();
    let st = std::process::Command::new("git")
        .args(["init", "--bare", "-q", bare.to_str().unwrap()])
        .status()
        .unwrap();
    assert!(st.success());
    git_in(&bare, &["symbolic-ref", "HEAD", "refs/heads/main"]);
    let bare_uri = file_uri(&bare);

    let r14 = tmp.path.join("r14-local");
    clone_seeded_git_repo(&r14);
    git_in(&r14, &["remote", "add", "origin", &bare_uri]);
    write_lf(
        &r14.join(".b3/research-policy.json"),
        r#"{"auto_merge":"authorized","protected_paths":["releases/"],"allow_protected_paths":false,"require_ci":true,"require_review":true,"allowed_target_branches":["main","release/*"]}"#,
    );
    write_lf(&r14.join("docs/a.md"), "base14\n");
    write_lf(&r14.join("docs/b.md"), "base14b\n");
    git_in(&r14, &["add", "."]);
    git_in(&r14, &["commit", "-qm", "r14 main"]);
    git_in(&r14, &["push", "-q", "-u", "origin", "main"]);
    let r14_main = git_in(&r14, &["rev-parse", "HEAD"]);

    git_in(&r14, &["checkout", "-qb", "feat/r14", &r14_main]);
    write_lf(&r14.join("docs/a.md"), "feat a 1\n");
    write_lf(&r14.join("docs/b.md"), "feat b 1\n");
    git_in(&r14, &["add", "."]);
    git_in(&r14, &["commit", "-qm", "c1"]);
    let r14_str = r14.to_str().unwrap();

    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            r14_str,
            "--verify-cmd",
            "echo c1",
            "--receipt-path",
            ".b3/ship/r14-stale.verify",
        ])
        .0,
        0
    );
    write_lf(&r14.join("docs/b.md"), "feat b 2\n");
    git_in(&r14, &["add", "."]);
    git_in(&r14, &["commit", "-qm", "c2"]);
    let r14_head = git_in(&r14, &["rev-parse", "HEAD"]);

    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            r14_str,
            "--verify-cmd",
            "echo narrow",
            "--receipt-path",
            ".b3/ship/r14-narrow.verify",
            "--relevant-paths",
            "docs/a.md",
        ])
        .0,
        0
    );
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            r14_str,
            "--verify-cmd",
            "echo full",
            "--receipt-path",
            ".b3/ship/r14-full.verify",
        ])
        .0,
        0
    );
    init_independent_ledger(&r14, ".b3/ship/r14-led.md", &r14_main);
    assert_eq!(
        run_b3(&[
            "guard",
            "review-ledger",
            "--repo-root",
            r14_str,
            "--action",
            "update",
            "--ledger-path",
            ".b3/ship/r14-led.md",
            "--unit-id",
            "U01",
            "--status",
            "REVIEWED",
            "--receipt-path",
            ".b3/ship/r14-full.verify",
        ])
        .0,
        0
    );

    // Stale & narrow receipt rejection + --require-remote-ci never downgrades
    let (sr_c, _, sr_err) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        r14_str,
        "--receipt-path",
        ".b3/ship/r14-stale.verify",
        "--ledger-path",
        ".b3/ship/r14-led.md",
        "--changed-paths",
        "docs/a.md,docs/b.md",
    ]);
    assert_eq!(sr_c, 1);
    assert!(sr_err.contains("ci_evidence_invalid("), "{sr_err}");

    let (nr_c, _, nr_err) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        r14_str,
        "--receipt-path",
        ".b3/ship/r14-narrow.verify",
        "--ledger-path",
        ".b3/ship/r14-led.md",
        "--changed-paths",
        "docs/a.md,docs/b.md",
    ]);
    assert_eq!(nr_c, 1);
    assert!(nr_err.contains("ci_evidence_invalid("), "{nr_err}");

    let (rrc_c, _, rrc_err) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        r14_str,
        "--require-remote-ci",
        "--receipt-path",
        ".b3/ship/r14-full.verify",
        "--ledger-path",
        ".b3/ship/r14-led.md",
        "--changed-paths",
        "docs/a.md,docs/b.md",
    ]);
    assert_eq!(rrc_c, 2);
    assert!(
        rrc_err.contains("PROVIDER_UNAVAILABLE: remote_ci_requires_provider_verification"),
        "{rrc_err}"
    );

    // Fresh bare remote -> LOCAL_ELIGIBLE_ONLY (exit 2)
    let (fr_c, _, fr_err) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        r14_str,
        "--ledger-path",
        ".b3/ship/r14-led.md",
        "--changed-paths",
        "docs/a.md,docs/b.md",
    ]);
    assert_eq!(fr_c, 2);
    assert!(fr_err.contains("LOCAL_ELIGIBLE_ONLY:"), "{fr_err}");

    // Advance bare remote without fetching -> stale_remote_ref
    let r14_clone = tmp.path.join("r14-other-clone");
    let cl_st = std::process::Command::new("git")
        .args([
            "clone",
            "-q",
            "-b",
            "main",
            &bare_uri,
            r14_clone.to_str().unwrap(),
        ])
        .status()
        .unwrap();
    assert!(cl_st.success());
    git_in(&r14_clone, &["config", "user.email", "other@b3.local"]);
    git_in(&r14_clone, &["config", "user.name", "Other"]);
    write_lf(&r14_clone.join("docs/remote-advance.md"), "adv\n");
    git_in(&r14_clone, &["add", "."]);
    git_in(&r14_clone, &["commit", "-qm", "adv"]);
    git_in(&r14_clone, &["push", "-q", "origin", "main"]);

    let (st_c, _, st_err) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        r14_str,
        "--ledger-path",
        ".b3/ship/r14-led.md",
        "--changed-paths",
        "docs/a.md,docs/b.md",
    ]);
    assert_eq!(st_c, 1);
    assert!(st_err.contains("stale_remote_ref("), "{st_err}");

    // Post-merge bare remote: unpushed merge fails, stale target fails, pushed+fetched passes, SEC-02 stale authority fails
    git_in(&r14, &["fetch", "-q", "origin"]);
    git_in(&r14, &["checkout", "-q", "main"]);
    git_in(&r14, &["merge", "--ff-only", "-q", "origin/main"]);
    git_in(&r14, &["merge", "--no-ff", "-qm", "merge r14", &r14_head]);
    let r14_merge = git_in(&r14, &["rev-parse", "HEAD"]);

    let (unp_c, _, unp_err) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        r14_str,
        "--post-merge",
        "--target-ref",
        "main",
        "--head-sha",
        &r14_head,
        "--merged-sha",
        &r14_merge,
    ]);
    assert_eq!(unp_c, 1);
    assert!(
        unp_err.contains("merge_commit_not_in_remote_target(target_ref=main)"),
        "{unp_err}"
    );

    // Push from clone without fetching in r14 -> stale_remote_target_ref
    write_lf(&r14_clone.join("docs/remote-adv-2.md"), "adv2\n");
    git_in(&r14_clone, &["add", "."]);
    git_in(&r14_clone, &["commit", "-qm", "adv2"]);
    git_in(&r14_clone, &["push", "-q", "origin", "main"]);
    let (stpm_c, _, stpm_err) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        r14_str,
        "--post-merge",
        "--target-ref",
        "main",
        "--head-sha",
        &r14_head,
        "--merged-sha",
        &r14_merge,
    ]);
    assert_eq!(stpm_c, 1);
    assert!(stpm_err.contains("stale_remote_target_ref("), "{stpm_err}");

    // Fetch, re-merge, push, fetch -> POST_MERGE_VERIFIED
    git_in(&r14, &["fetch", "-q", "origin"]);
    git_in(&r14, &["reset", "--hard", "-q", "origin/main"]);
    git_in(&r14, &["merge", "--no-ff", "-qm", "merge clean", &r14_head]);
    let r14_merge2 = git_in(&r14, &["rev-parse", "HEAD"]);
    git_in(&r14, &["push", "-q", "origin", "main"]);
    git_in(&r14, &["fetch", "-q", "origin"]);
    let (pmok_c, pmok_out, pmok_err) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        r14_str,
        "--post-merge",
        "--target-ref",
        "main",
        "--head-sha",
        &r14_head,
        "--merged-sha",
        &r14_merge2,
    ]);
    assert_eq!(pmok_c, 0, "{pmok_out}\n{pmok_err}");
    assert!(
        pmok_out.contains("POST_MERGE_VERIFIED: mode=local"),
        "{pmok_out}"
    );

    // SEC-02: release/v1 fresh, main authority stale remotely -> stale_remote_authority_ref
    git_in(&r14, &["checkout", "-qb", "release/v1", &r14_merge2]);
    git_in(&r14, &["checkout", "-qb", "feat/rel-v1", &r14_merge2]);
    write_lf(&r14.join("docs/rel-feat.md"), "rf\n");
    git_in(&r14, &["add", "."]);
    git_in(&r14, &["commit", "-qm", "rf"]);
    let rel_head = git_in(&r14, &["rev-parse", "HEAD"]);
    git_in(&r14, &["checkout", "-q", "release/v1"]);
    git_in(&r14, &["merge", "--no-ff", "-qm", "merge rel", &rel_head]);
    let rel_merge = git_in(&r14, &["rev-parse", "HEAD"]);
    git_in(&r14, &["push", "-q", "origin", "release/v1"]);
    git_in(&r14, &["fetch", "-q", "origin", "release/v1"]);

    git_in(&r14_clone, &["pull", "-q", "origin", "main"]);
    write_lf(&r14_clone.join("docs/sec02.md"), "adv trunk\n");
    git_in(&r14_clone, &["add", "."]);
    git_in(&r14_clone, &["commit", "-qm", "adv trunk"]);
    git_in(&r14_clone, &["push", "-q", "origin", "main"]);
    let (sec02_c, _, sec02_err) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        r14_str,
        "--post-merge",
        "--target-ref",
        "release/v1",
        "--head-sha",
        &rel_head,
        "--merged-sha",
        &rel_merge,
    ]);
    assert_eq!(sec02_c, 1);
    assert!(
        sec02_err.contains("stale_remote_authority_ref("),
        "{sec02_err}"
    );
}

#[test]
fn zero_remote_gitlab_ledger_binding_and_json_hardening() {
    let tmp = TempDirGuard::new("mp-gl-led-json");
    let mock_bin = tmp.path.join("mock-bin");
    write_mock_gh(&mock_bin, "gh", MOCK_GH_JS);
    let mock_path = path_with_prepended(&mock_bin);

    // 1. Zero-remote & GitLab local-only vs origin_remote_not_github
    let r_gl = tmp.path.join("r-gitlab");
    clone_seeded_git_repo(&r_gl);
    git_in(
        &r_gl,
        &["remote", "add", "origin", "https://gitlab.com/org/repo.git"],
    );
    write_lf(
        &r_gl.join(".b3/research-policy.json"),
        r#"{"auto_merge":"authorized","protected_paths":["releases/"],"allow_protected_paths":false,"require_ci":false,"require_review":true}"#,
    );
    git_in(&r_gl, &["add", "."]);
    git_in(&r_gl, &["commit", "-qm", "gl main"]);
    let gl_main = git_in(&r_gl, &["rev-parse", "HEAD"]);
    git_in(&r_gl, &["update-ref", "refs/remotes/origin/main", &gl_main]);
    git_in(
        &r_gl,
        &[
            "symbolic-ref",
            "refs/remotes/origin/HEAD",
            "refs/remotes/origin/main",
        ],
    );
    git_in(&r_gl, &["checkout", "-qb", "feat/gl", &gl_main]);
    write_lf(&r_gl.join("docs/gl.md"), "gl\n");
    git_in(&r_gl, &["add", "."]);
    git_in(&r_gl, &["commit", "-qm", "gl feat"]);
    let gl_str = r_gl.to_str().unwrap();
    init_independent_ledger(&r_gl, ".b3/ship/l-gl.md", &gl_main);

    let (gl_c, _, gl_err) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        gl_str,
        "--ledger-path",
        ".b3/ship/l-gl.md",
    ]);
    assert_eq!(gl_c, 2);
    assert!(
        gl_err.contains("LOCAL_ELIGIBLE_ONLY: engineering_ready=true remote_authorization=UNVERIFIED(remote_ref_unverifiable)"),
        "{gl_err}"
    );

    let (gl_pr_c, _, gl_pr_err) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        gl_str,
        "--pr-number",
        "55",
        "--base-sha",
        &gl_main,
        "--ledger-path",
        ".b3/ship/l-gl.md",
    ]);
    assert_eq!(gl_pr_c, 1);
    assert!(
        gl_pr_err.contains("origin_remote_not_github"),
        "{gl_pr_err}"
    );

    // 2. Cross-PR/commit ledger mismatch, tamper, UNKNOWN, SINGLE_AGENT_LIMIT
    let slug = "octo/b3-led";
    let r_led = tmp.path.join("r-led");
    clone_seeded_git_repo(&r_led);
    git_in(
        &r_led,
        &[
            "remote",
            "add",
            "origin",
            &format!("https://github.com/{slug}.git"),
        ],
    );
    write_lf(
        &r_led.join(".b3/research-policy.json"),
        r#"{"auto_merge":"authorized","protected_paths":[],"allow_protected_paths":false,"require_ci":true,"require_review":true}"#,
    );
    git_in(&r_led, &["add", "."]);
    git_in(&r_led, &["commit", "-qm", "main"]);
    let lm_sha = git_in(&r_led, &["rev-parse", "HEAD"]);
    git_in(&r_led, &["checkout", "-qb", "develop", &lm_sha]);
    write_lf(&r_led.join("docs/dev.md"), "dev\n");
    git_in(&r_led, &["add", "."]);
    git_in(&r_led, &["commit", "-qm", "dev"]);
    let dev_sha = git_in(&r_led, &["rev-parse", "HEAD"]);
    git_in(&r_led, &["checkout", "-qb", "feat/pr-11", &lm_sha]);
    write_lf(&r_led.join("docs/pr11.md"), "p11\n");
    git_in(&r_led, &["add", "."]);
    git_in(&r_led, &["commit", "-qm", "p11"]);
    let h11_sha = git_in(&r_led, &["rev-parse", "HEAD"]);
    let rl_str = r_led.to_str().unwrap();

    let fx11 = tmp.path.join("fx-led-11");
    write_premerge_fixtures(
        &fx11,
        slug,
        11,
        "main",
        &lm_sha,
        "main",
        &lm_sha,
        &lm_sha,
        "feat/pr-11",
        &h11_sha,
        Some("success"),
        "completed",
        true,
        "clean",
        "docs/pr11.md",
        slug,
        "pending",
        0,
    );

    // Ledger from another target ref (feat/pr-12) -> ledger_target_mismatch
    assert_eq!(
        run_b3(&[
            "guard",
            "review-ledger",
            "--repo-root",
            rl_str,
            "--action",
            "init",
            "--ledger-path",
            ".b3/ship/other-ref.md",
            "--base-sha",
            &dev_sha,
            "--target-ref",
            "feat/pr-11",
            "--review-independence",
            "INDEPENDENT",
        ])
        .0,
        0
    );
    assert_eq!(
        run_b3(&[
            "guard",
            "review-ledger",
            "--repo-root",
            rl_str,
            "--action",
            "update",
            "--ledger-path",
            ".b3/ship/other-ref.md",
            "--unit-id",
            "U01",
            "--status",
            "REVIEWED",
        ])
        .0,
        0
    );
    let (lt_c, _, lt_err) = run_b3_env(
        &[
            "guard",
            "merge-policy-check",
            "--repo-root",
            rl_str,
            "--pr-number",
            "11",
            "--ledger-path",
            ".b3/ship/other-ref.md",
        ],
        None,
        &[
            ("PATH", &mock_path),
            ("B3_TEST_GH_DIR", fx11.to_str().unwrap()),
        ],
        &["B3_GH_BIN"],
    );
    assert_eq!(lt_c, 1);
    assert!(lt_err.contains("ledger_target_mismatch"), "{lt_err}");

    // Ledger for another commit -> ledger_head_mismatch
    assert_eq!(
        run_b3(&[
            "guard",
            "review-ledger",
            "--repo-root",
            rl_str,
            "--action",
            "init",
            "--ledger-path",
            ".b3/ship/other-head.md",
            "--base-sha",
            &lm_sha,
            "--target-ref",
            "develop",
            "--review-independence",
            "INDEPENDENT",
        ])
        .0,
        0
    );
    assert_eq!(
        run_b3(&[
            "guard",
            "review-ledger",
            "--repo-root",
            rl_str,
            "--action",
            "update",
            "--ledger-path",
            ".b3/ship/other-head.md",
            "--unit-id",
            "U01",
            "--status",
            "REVIEWED",
        ])
        .0,
        0
    );
    let (lh_c, _, lh_err) = run_b3_env(
        &[
            "guard",
            "merge-policy-check",
            "--repo-root",
            rl_str,
            "--pr-number",
            "11",
            "--ledger-path",
            ".b3/ship/other-head.md",
        ],
        None,
        &[
            ("PATH", &mock_path),
            ("B3_TEST_GH_DIR", fx11.to_str().unwrap()),
        ],
        &["B3_GH_BIN"],
    );
    assert_eq!(lh_c, 1);
    assert!(lh_err.contains("ledger_head_mismatch"), "{lh_err}");

    // UNKNOWN and SINGLE_AGENT_LIMIT block merge
    for (ri_opt, expected) in [
        ("UNKNOWN", "review_independence_unknown"),
        ("SINGLE_AGENT_LIMIT", "single_agent_limit"),
    ] {
        let lp_ri = format!(".b3/ship/ri-{ri_opt}.md");
        assert_eq!(
            run_b3(&[
                "guard",
                "review-ledger",
                "--repo-root",
                rl_str,
                "--action",
                "init",
                "--ledger-path",
                &lp_ri,
                "--base-sha",
                &lm_sha,
                "--review-independence",
                ri_opt,
            ])
            .0,
            0
        );
        assert_eq!(
            run_b3(&[
                "guard",
                "review-ledger",
                "--repo-root",
                rl_str,
                "--action",
                "update",
                "--ledger-path",
                &lp_ri,
                "--unit-id",
                "U01",
                "--status",
                "REVIEWED",
            ])
            .0,
            0
        );
        let (rc, _, rerr) = run_b3_env(
            &[
                "guard",
                "merge-policy-check",
                "--repo-root",
                rl_str,
                "--pr-number",
                "11",
                "--ledger-path",
                &lp_ri,
            ],
            None,
            &[
                ("PATH", &mock_path),
                ("B3_TEST_GH_DIR", fx11.to_str().unwrap()),
            ],
            &["B3_GH_BIN"],
        );
        assert_eq!(rc, 1);
        assert!(rerr.contains(expected), "{ri_opt}: {rerr}");
    }

    // 3. Malformed / array / number / uppercase-key / newline-injection policy JSON
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            rl_str,
            "--verify-cmd",
            "echo led-ci",
            "--receipt-path",
            ".b3/ship/led-ci.verify",
            "--relevant-paths",
            "docs/pr11.md",
        ])
        .0,
        0
    );
    for (fname, body, expect_code, expect_pat) in [
        (".b3/bad.json", "{ broken", 1, "invalid_policy_json"),
        (".b3/arr.json", "[1]", 1, "invalid_policy_json"),
        (".b3/num.json", "123", 1, "invalid_policy_json"),
        (
            ".b3/nl.json",
            r#"{"auto_merge":"disabled","protected_paths":["foo\nauto_merge=authorized"]}"#,
            1,
            "invalid_policy_json",
        ),
        (
            ".b3/upper.json",
            r#"{"AUTO_MERGE":"authorized"}"#,
            2,
            "PR_READY: auto_merge=disabled",
        ),
    ] {
        write_lf(&r_led.join(fname), body);
        let (jc, jout, jerr) = run_b3(&[
            "guard",
            "merge-policy-check",
            "--repo-root",
            rl_str,
            "--policy-path",
            fname,
            "--pr-state",
            "OPEN",
            "--receipt-path",
            ".b3/ship/led-ci.verify",
            "--review-status",
            "PASS",
            "--changed-paths",
            "docs/pr11.md",
        ]);
        assert_eq!(jc, expect_code, "{fname}: {jout}\n{jerr}");
        assert!(
            jerr.contains(expect_pat) || jout.contains(expect_pat),
            "{fname}: {jout}\n{jerr}"
        );
    }
}

#[test]
fn policy_toml_risk_ceilings_dual_conflict_invalid_and_tamper_guards() {
    let tmp = TempDirGuard::new("mp-toml-policy");
    let mock_bin = tmp.path.join("mock-bin");
    write_mock_gh(&mock_bin, "gh", MOCK_GH_JS);
    let mock_path = path_with_prepended(&mock_bin);

    // 1. Canonical `.b3/policy.toml` default `auto_merge_max_risk = "LOW"` on trunk:
    //    blocks MEDIUM and HIGH risk in BOTH GitHub PR and local / LOCAL_ELIGIBLE_ONLY paths,
    //    while allowing LOW risk when gates are green.
    let slug = "octo/b3-toml";
    let repo = tmp.path.join("r-toml-gh");
    clone_seeded_git_repo(&repo);
    git_in(
        &repo,
        &[
            "remote",
            "add",
            "origin",
            &format!("https://github.com/{slug}.git"),
        ],
    );
    // Omitted `auto_merge_max_risk` in `.b3/policy.toml` defaults strictly to "LOW".
    write_lf(
        &repo.join(".b3/policy.toml"),
        "auto_merge = \"authorized\"\nprotected_paths = [\"releases/\"]\nallow_protected_paths = false\nallowed_target_branches = [\"main\"]\nrequire_ci = true\nrequire_review = true\n",
    );
    git_in(&repo, &["add", "."]);
    git_in(&repo, &["commit", "-qm", "main policy.toml"]);
    let main_sha = git_in(&repo, &["rev-parse", "HEAD"]);
    git_in(
        &repo,
        &["update-ref", "refs/remotes/origin/main", &main_sha],
    );
    git_in(
        &repo,
        &[
            "symbolic-ref",
            "refs/remotes/origin/HEAD",
            "refs/remotes/origin/main",
        ],
    );
    let r_str = repo.to_str().unwrap();

    // 1a. LOW risk branch (docs only) -> MERGE_AUTHORIZED in GitHub PR mode
    git_in(&repo, &["checkout", "-qb", "feat/low", &main_sha]);
    write_lf(&repo.join("docs/low.md"), "low\n");
    git_in(&repo, &["add", "."]);
    git_in(&repo, &["commit", "-qm", "low"]);
    let low_sha = git_in(&repo, &["rev-parse", "HEAD"]);
    init_independent_ledger(&repo, ".b3/ship/low.md", &main_sha);
    let fx_low = tmp.path.join("fx-low");
    write_premerge_fixtures(
        &fx_low,
        slug,
        101,
        "main",
        &main_sha,
        "main",
        &main_sha,
        &main_sha,
        "feat/low",
        &low_sha,
        Some("success"),
        "completed",
        true,
        "clean",
        "docs/low.md",
        slug,
        "pending",
        0,
    );
    let (cl, outl, errl) = run_b3_env(
        &[
            "guard",
            "merge-policy-check",
            "--repo-root",
            r_str,
            "--pr-number",
            "101",
            "--ledger-path",
            ".b3/ship/low.md",
        ],
        None,
        &[
            ("PATH", &mock_path),
            ("B3_TEST_GH_DIR", fx_low.to_str().unwrap()),
        ],
        &["B3_GH_BIN"],
    );
    assert_eq!(cl, 0, "LOW risk should pass: {outl}\n{errl}");
    assert!(outl.contains("MERGE_AUTHORIZED: mode=github"), "{outl}");

    // 1b. MEDIUM risk branch (2 code files -> general_code_change / MEDIUM) -> blocked by max=LOW
    git_in(&repo, &["checkout", "-qb", "feat/med", &main_sha]);
    write_lf(&repo.join("src/a.rs"), "pub fn a() {}\n");
    write_lf(&repo.join("src/b.rs"), "pub fn b() {}\n");
    git_in(&repo, &["add", "."]);
    git_in(&repo, &["commit", "-qm", "med"]);
    let med_sha = git_in(&repo, &["rev-parse", "HEAD"]);
    init_independent_ledger(&repo, ".b3/ship/med.md", &main_sha);
    let fx_med = tmp.path.join("fx-med");
    write_premerge_fixtures(
        &fx_med,
        slug,
        102,
        "main",
        &main_sha,
        "main",
        &main_sha,
        &main_sha,
        "feat/med",
        &med_sha,
        Some("success"),
        "completed",
        true,
        "clean",
        "src/a.rs",
        slug,
        "pending",
        0,
    );
    let (cm, outm, errm) = run_b3_env(
        &[
            "guard",
            "merge-policy-check",
            "--repo-root",
            r_str,
            "--pr-number",
            "102",
            "--ledger-path",
            ".b3/ship/med.md",
        ],
        None,
        &[
            ("PATH", &mock_path),
            ("B3_TEST_GH_DIR", fx_med.to_str().unwrap()),
        ],
        &["B3_GH_BIN"],
    );
    assert_eq!(cm, 1, "MEDIUM risk must block at max=LOW: {outm}\n{errm}");
    assert!(
        errm.contains("MERGE_BLOCKED: risk_exceeds_policy(risk=MEDIUM,max=LOW)"),
        "{errm}"
    );

    // Local / LOCAL_ELIGIBLE_ONLY path also blocks MEDIUM risk at max=LOW
    let (cm_loc, outm_loc, errm_loc) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        r_str,
        "--local-only",
        "--base-sha",
        &main_sha,
        "--ledger-path",
        ".b3/ship/med.md",
    ]);
    assert_eq!(cm_loc, 1, "{outm_loc}\n{errm_loc}");
    assert!(
        errm_loc.contains("MERGE_BLOCKED: risk_exceeds_policy(risk=MEDIUM,max=LOW)"),
        "{errm_loc}"
    );

    // 1c. HIGH risk branch (api/contract.rs -> public_api_contract / HIGH) -> blocked at max=LOW
    git_in(&repo, &["checkout", "-qb", "feat/high", &main_sha]);
    write_lf(&repo.join("api/endpoint.rs"), "pub fn api() {}\n");
    git_in(&repo, &["add", "."]);
    git_in(&repo, &["commit", "-qm", "high"]);
    let high_sha = git_in(&repo, &["rev-parse", "HEAD"]);
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            r_str,
            "--verify-cmd",
            "echo ok",
            "--receipt-path",
            ".b3/ship/high.verify",
        ])
        .0,
        0
    );
    init_independent_ledger(&repo, ".b3/ship/high.md", &main_sha);
    assert_eq!(
        run_b3(&[
            "guard",
            "review-ledger",
            "--repo-root",
            r_str,
            "--action",
            "update",
            "--ledger-path",
            ".b3/ship/high.md",
            "--unit-id",
            "U01",
            "--status",
            "REVIEWED",
            "--specialists",
            "b3-architecture-reviewer",
            "--receipt-path",
            ".b3/ship/high.verify",
        ])
        .0,
        0
    );
    let fx_high = tmp.path.join("fx-high");
    write_premerge_fixtures(
        &fx_high,
        slug,
        103,
        "main",
        &main_sha,
        "main",
        &main_sha,
        &main_sha,
        "feat/high",
        &high_sha,
        Some("success"),
        "completed",
        true,
        "clean",
        "api/endpoint.rs",
        slug,
        "pending",
        0,
    );
    let (ch, outh, errh) = run_b3_env(
        &[
            "guard",
            "merge-policy-check",
            "--repo-root",
            r_str,
            "--pr-number",
            "103",
            "--ledger-path",
            ".b3/ship/high.md",
        ],
        None,
        &[
            ("PATH", &mock_path),
            ("B3_TEST_GH_DIR", fx_high.to_str().unwrap()),
        ],
        &["B3_GH_BIN"],
    );
    assert_eq!(ch, 1, "HIGH risk must block at max=LOW: {outh}\n{errh}");
    assert!(
        errh.contains("MERGE_BLOCKED: risk_exceeds_policy(risk=HIGH,max=LOW)"),
        "{errh}"
    );

    // 1d. Policy tamper detection: modifying `.b3/policy.toml` on feature branch -> policy_modified_in_pr
    git_in(&repo, &["checkout", "-qb", "feat/tamper", &main_sha]);
    write_lf(
        &repo.join(".b3/policy.toml"),
        "auto_merge = \"authorized\"\nauto_merge_max_risk = \"CRITICAL\"\nrequire_ci = false\nrequire_review = false\n",
    );
    git_in(&repo, &["add", "."]);
    git_in(&repo, &["commit", "-qm", "tamper policy"]);
    let (ct, outt, errt) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        r_str,
        "--local-only",
        "--base-sha",
        &main_sha,
    ]);
    assert_eq!(ct, 1, "tampered policy.toml must fail: {outt}\n{errt}");
    assert!(errt.contains("policy_modified_in_pr"), "{errt}");

    // 2. When trunk `.b3/policy.toml` sets `auto_merge_max_risk = "HIGH"` and gates are green, HIGH risk passes
    let r_high_ok = tmp.path.join("r-toml-high-ok");
    clone_seeded_git_repo(&r_high_ok);
    write_lf(
        &r_high_ok.join(".b3/policy.toml"),
        "auto_merge = \"authorized\"\nauto_merge_max_risk = \"HIGH\"\nallowed_target_branches = [\"main\"]\nrequire_ci = true\nrequire_review = true\n",
    );
    git_in(&r_high_ok, &["add", "."]);
    git_in(&r_high_ok, &["commit", "-qm", "main high policy"]);
    let mh_sha = git_in(&r_high_ok, &["rev-parse", "HEAD"]);
    git_in(&r_high_ok, &["checkout", "-qb", "feat/api", &mh_sha]);
    write_lf(&r_high_ok.join("api/endpoint.rs"), "pub fn api() {}\n");
    git_in(&r_high_ok, &["add", "."]);
    git_in(&r_high_ok, &["commit", "-qm", "api"]);
    let rh_str = r_high_ok.to_str().unwrap();
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            rh_str,
            "--verify-cmd",
            "echo ok",
            "--receipt-path",
            ".b3/ship/high-ok.verify",
        ])
        .0,
        0
    );
    init_independent_ledger(&r_high_ok, ".b3/ship/high-ok.md", &mh_sha);
    assert_eq!(
        run_b3(&[
            "guard",
            "review-ledger",
            "--repo-root",
            rh_str,
            "--action",
            "update",
            "--ledger-path",
            ".b3/ship/high-ok.md",
            "--unit-id",
            "U01",
            "--status",
            "REVIEWED",
            "--specialists",
            "b3-architecture-reviewer",
            "--receipt-path",
            ".b3/ship/high-ok.verify",
        ])
        .0,
        0
    );
    let (cho, outho, errho) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        rh_str,
        "--receipt-path",
        ".b3/ship/high-ok.verify",
        "--ledger-path",
        ".b3/ship/high-ok.md",
    ]);
    assert_eq!(
        cho, 0,
        "HIGH risk with max=HIGH must pass: {outho}\n{errho}"
    );
    assert!(outho.contains("MERGE_AUTHORIZED: mode=local"), "{outho}");

    // 3. Dual-format conflict (both `.b3/policy.toml` and `.b3/research-policy.json` exist)
    let r_dual = tmp.path.join("r-dual");
    clone_seeded_git_repo(&r_dual);
    write_lf(
        &r_dual.join(".b3/policy.toml"),
        "auto_merge = \"disabled\"\n",
    );
    write_lf(
        &r_dual.join(".b3/research-policy.json"),
        r#"{"auto_merge":"disabled"}"#,
    );
    git_in(&r_dual, &["add", "."]);
    git_in(&r_dual, &["commit", "-qm", "dual policy"]);
    let (c_dual, out_dual, err_dual) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        r_dual.to_str().unwrap(),
    ]);
    assert_eq!(c_dual, 1, "{out_dual}\n{err_dual}");
    assert!(
        err_dual.contains("policy_conflict_dual_format"),
        "{err_dual}"
    );

    // 4. Invalid `.b3/policy.toml` fails closed (`invalid_policy_toml`)
    for bad_toml in [
        "[section]\nauto_merge = \"disabled\"\n",
        "unknown_key = true\n",
        "auto_merge_max_risk = \"EXTREME\"\n",
        "auto_merge = \"unterminated\n",
    ] {
        let r_inv = tmp.path.join("r-inv-toml");
        let _ = b3::fs::remove_dir_tree_safely(&r_inv);
        clone_seeded_git_repo(&r_inv);
        write_lf(&r_inv.join(".b3/policy.toml"), bad_toml);
        git_in(&r_inv, &["add", "."]);
        git_in(&r_inv, &["commit", "-qm", "bad toml"]);
        let (ci, outi, erri) = run_b3(&[
            "guard",
            "merge-policy-check",
            "--repo-root",
            r_inv.to_str().unwrap(),
        ]);
        assert_eq!(ci, 1, "{bad_toml}: {outi}\n{erri}");
        assert!(erri.contains("invalid_policy_toml"), "{bad_toml}: {erri}");
    }

    // 5. SEC-1 regression: forged `risk_level=LOW` in ledger header cannot bypass `auto_merge_max_risk = "LOW"`
    let r_tamper_led = tmp.path.join("r-tamper-led");
    clone_seeded_git_repo(&r_tamper_led);
    write_lf(
        &r_tamper_led.join(".b3/policy.toml"),
        "auto_merge = \"authorized\"\nauto_merge_max_risk = \"LOW\"\nrequire_ci = false\nrequire_review = true\n",
    );
    git_in(&r_tamper_led, &["add", "."]);
    git_in(&r_tamper_led, &["commit", "-qm", "strict policy"]);
    let base_t = git_in(&r_tamper_led, &["rev-parse", "HEAD"]);

    git_in(&r_tamper_led, &["checkout", "-qb", "feat/sec1-tamper"]);
    // Benign path name `src/app.rs` containing destructive SQL -> content-based HIGH/CRITICAL signal
    write_lf(
        &r_tamper_led.join("src/app.rs"),
        "pub fn dangerous() { let _q = \"DROP TABLE users;\"; }\n",
    );
    git_in(&r_tamper_led, &["add", "src/app.rs"]);
    git_in(&r_tamper_led, &["commit", "-qm", "destructive query"]);
    let head_t = git_in(&r_tamper_led, &["rev-parse", "HEAD"]);

    let rt_str = r_tamper_led.to_str().unwrap();
    let (cli_t, _, _) = run_b3(&[
        "guard",
        "review-ledger",
        "--action",
        "init",
        "--repo-root",
        rt_str,
        "--ledger-path",
        ".b3/ship/tamper.md",
        "--base-sha",
        &base_t,
        "--target-ref",
        &head_t,
        "--review-independence",
        "INDEPENDENT",
    ]);
    assert_eq!(cli_t, 0);
    let led_raw = fs::read_to_string(r_tamper_led.join(".b3/ship/tamper.md")).unwrap();
    let tampered = led_raw.replace("risk_level=CRITICAL", "risk_level=LOW");
    let tampered = tampered.replace("risk_level=HIGH", "risk_level=LOW");
    write_lf(&r_tamper_led.join(".b3/ship/tamper.md"), &tampered);

    let (cm_t, outm_t, errm_t) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        rt_str,
        "--ledger-path",
        ".b3/ship/tamper.md",
    ]);
    assert_eq!(
        cm_t, 1,
        "tampered risk_level header must fail: {outm_t}\n{errm_t}"
    );
    assert!(
        errm_t.contains("LEDGER_STALE") || errm_t.contains("risk_exceeds_policy"),
        "{errm_t}"
    );
}
