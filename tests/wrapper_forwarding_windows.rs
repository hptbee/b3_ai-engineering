#![cfg(windows)]
//! Focused Windows thin-wrapper argument-forwarding regression tests.
//! Validates that `scripts/*.ps1` and `adapters/*.ps1` forward arguments,
//! quoting, trailing backslashes, exit codes, and `B3_BIN` cleanly to `b3.exe`.
//! Full behavioral parity lives in `tests/native_golden_parity.rs` and `tests/native_core_behaviors.rs`.

mod common;

use common::{b3_bin, git_in, init_git_repo, norm_lf, repo_root, run_b3, TempDirGuard};
use std::fs;
use std::path::Path;
use std::process::{Command, Output};

fn run_ps_script(script_rel: &str, args: &[&str]) -> (i32, String) {
    run_ps_script_env(script_rel, args, &[])
}

fn run_ps_script_env(script_rel: &str, args: &[&str], envs: &[(&str, &str)]) -> (i32, String) {
    let script = repo_root().join(script_rel);
    let mut cmd = Command::new("powershell");
    cmd.env("B3_BIN", b3_bin())
        .arg("-NoProfile")
        .arg("-ExecutionPolicy")
        .arg("Bypass")
        .arg("-File")
        .arg(script)
        .args(args);
    for (k, v) in envs {
        cmd.env(k, v);
    }
    let out: Output = cmd.output().expect("run powershell script");
    (out.status.code().unwrap_or(-1), norm_lf(&out.stdout))
}

fn replace_path_variants(mut s: String, path: &Path, token: &str) -> String {
    let long = b3::fs::expand_windows_long_path(path);
    for p in [long.to_string_lossy().into_owned(), path.to_string_lossy().into_owned()] {
        if !p.is_empty() {
            s = s.replace(&p, token);
            s = s.replace(&p.replace('\\', "/"), token);
        }
    }
    s
}

#[test]
fn wrapper_forwarding_context_measure_strict_matches_powershell() {
    let root = repo_root();
    let root_str = root.to_str().unwrap();
    let (rust_code, rust_out, _) =
        run_b3(&["context", "measure", "--repo-root", root_str, "--strict"]);
    let (ps_code, ps_out) = run_ps_script(
        "scripts/measure-context.ps1",
        &["-RepoRoot", root_str, "-Strict"],
    );
    assert_eq!(rust_code, 0);
    assert_eq!(ps_code, rust_code);
    assert_eq!(ps_out, rust_out);
}

#[test]
fn wrapper_forwarding_b3_guard_args_quoting_and_exit_codes() {
    // 1. Array + comma-separated argument forwarding (fingerprint)
    let (rc1, ro1, _) = run_b3(&[
        "guard",
        "fingerprint",
        "--depends-on",
        "T2,T1",
        "--scope",
        " src/a.rs ",
        "--criteria",
        "AC1: one",
    ]);
    let (pc1, po1) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "fingerprint",
            "-DependsOn",
            "T2,T1",
            "-Scope",
            " src/a.rs ",
            "-Criteria",
            "AC1: one",
        ],
    );
    assert_eq!(rc1, 0);
    assert_eq!(pc1, rc1);
    assert_eq!(po1, ro1);

    // 2. Quoted VerifyCmd + trailing backslash on RepoRoot + exit code 0/2/1 forwarding
    let tmp = TempDirGuard::new("guard-fwd");
    let repo = tmp.path.join("repo with spaces");
    let head = init_git_repo(&repo);
    let repo_str = repo.to_str().unwrap();
    let repo_trailing = format!("{repo_str}\\");
    let receipt = repo.join(".b3/ship/runs/test/evidence/T001.verify");
    let receipt_str = receipt.to_str().unwrap();

    let (vc_rust, vo_rust, _) = run_b3(&[
        "guard",
        "verify-run",
        "--repo-root",
        repo_str,
        "--task-id",
        "T001",
        "--verify-cmd",
        "node -e \"console.log('ok')\"",
        "--receipt-path",
        receipt_str,
    ]);
    assert_eq!(vc_rust, 0, "{vo_rust}");

    let (vc_ps, vo_ps) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "verify-run",
            "-RepoRoot",
            &repo_trailing,
            "-TaskId",
            "T001",
            "-VerifyCmd",
            "node -e \"console.log('ok')\"",
            "-ReceiptPath",
            receipt_str,
        ],
    );
    assert_eq!(vc_ps, 0, "{vo_ps}");

    // Exit code 2 forwarding (diff-scope EMPTY_DIFF)
    let (dc_rust, do_rust, _) = run_b3(&[
        "guard",
        "diff-scope",
        "--repo-root",
        repo_str,
        "--base-sha",
        &head,
    ]);
    let (dc_ps, do_ps) = run_ps_script(
        "scripts/b3-guard.ps1",
        &["diff-scope", "-RepoRoot", &repo_trailing, "-BaseSha", &head],
    );
    assert_eq!(dc_rust, 2);
    assert_eq!(dc_ps, 2);
    assert_eq!(do_ps, do_rust);

    // Exit code 1 forwarding (precommit empty staging)
    let (pc_rust, po_rust, _) = run_b3(&[
        "guard",
        "precommit",
        "--repo-root",
        repo_str,
        "--allowed-paths",
        "src/app.txt",
    ]);
    let (pc_ps, po_ps) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "precommit",
            "-RepoRoot",
            repo_str,
            "-AllowedPaths",
            "src/app.txt",
        ],
    );
    assert_eq!(pc_rust, 1);
    assert_eq!(pc_ps, 1);
    assert_eq!(po_ps, po_rust);
}

#[test]
fn wrapper_forwarding_pr_verify_and_pr_github_match_b3() {
    let tmp = TempDirGuard::new("pr-fwd");
    let repo = tmp.path.join("repo");
    init_git_repo(&repo);
    git_in(
        &repo,
        &[
            "remote",
            "add",
            "origin",
            "https://github.com/octocat/hello-world.git",
        ],
    );

    // 1. b3-github-verify.ps1 exit code 2 when gh is missing (keep System32 & git on PATH)
    let empty_bin = tmp.path.join("empty-bin");
    fs::create_dir_all(&empty_bin).unwrap();
    let nogh_path = std::env::var("PATH")
        .unwrap_or_default()
        .split(';')
        .filter(|p| {
            let candidate = Path::new(p);
            !candidate.join("gh.exe").exists() && !candidate.join("gh.cmd").exists() && !candidate.join("gh").exists()
        })
        .collect::<Vec<_>>()
        .join(";");
    let (vc_rust, vo_rust, _) = common::run_b3_with_env(
        &[
            "pr",
            "verify",
            "--mode",
            "pre-merge",
            "--repo",
            "octocat/hello-world",
            "--pr-number",
            "1",
            "--repo-root",
            repo.to_str().unwrap(),
        ],
        &[("PATH", &nogh_path)],
    );
    let (vc_ps, vo_ps) = run_ps_script_env(
        "scripts/b3-github-verify.ps1",
        &[
            "-Mode",
            "pre-merge",
            "-Repo",
            "octocat/hello-world",
            "-PrNumber",
            "1",
            "-RepoRoot",
            repo.to_str().unwrap(),
        ],
        &[("PATH", &nogh_path)],
    );
    assert_eq!(vc_rust, 2);
    assert_eq!(vc_ps, 2);
    assert_eq!(vo_ps, vo_rust);

    // 2. b3-pr-github.ps1 forwards fetch with mock gh.cmd
    let mock_bin = tmp.path.join("mock-bin");
    fs::create_dir_all(&mock_bin).unwrap();
    let gh_cmd = mock_bin.join("gh.cmd");
    fs::write(
        &gh_cmd,
        "@echo off\r\nif \"%1\"==\"--version\" (echo gh version 2.0.0 & exit /b 0)\r\nif \"%1\"==\"auth\" (echo Logged in & exit /b 0)\r\necho {}\r\n",
    )
    .unwrap();
    let path_with_mock = format!(
        "{};{}",
        mock_bin.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let (pc_ps, _) = run_ps_script_env(
        "scripts/b3-pr-github.ps1",
        &[
            "fetch",
            "-Repo",
            "octocat/hello-world",
            "-PrNumber",
            "1",
            "-RepoRoot",
            repo.to_str().unwrap(),
        ],
        &[("PATH", &path_with_mock)],
    );
    // Expect non-crash forwarding (mock returns `{}` -> PR_FETCH_ERROR / exit 1, same as b3 pr fetch)
    let (pc_rust, _, _) = common::run_b3_with_env(
        &[
            "pr",
            "fetch",
            "--repo",
            "octocat/hello-world",
            "--pr-number",
            "1",
            "--repo-root",
            repo.to_str().unwrap(),
        ],
        &[("PATH", &path_with_mock)],
    );
    assert_eq!(pc_ps, pc_rust);
}

#[test]
fn wrapper_forwarding_adapters_sync_product_and_global_dry_run() {
    let tmp = TempDirGuard::new("adapters-fwd");
    let product = tmp.path.join("product");
    init_git_repo(&product);
    let product_str = product.to_str().unwrap();

    // install-product.ps1 -DryRun
    let root = repo_root();
    let root_str = root.to_str().unwrap();
    let (ip_rust, io_rust, _) = run_b3(&[
        "install",
        "product",
        "--b3-home",
        root_str,
        "--product-root",
        product_str,
        "--dry-run",
    ]);
    let (ip_ps, io_ps) = run_ps_script(
        "adapters/install-product.ps1",
        &["-ProductRoot", product_str, "-DryRun"],
    );
    assert_eq!(ip_rust, 0, "{io_rust}");
    assert_eq!(ip_ps, ip_rust);
    assert_eq!(
        replace_path_variants(io_ps, &product, "<PRODUCT>"),
        replace_path_variants(io_rust, &product, "<PRODUCT>")
    );

    // sync-skills.ps1 -DryRun (against B3 repo_root which has canonical skills/commands/agents)
    let (ss_rust, so_rust, _) = run_b3(&[
        "sync",
        "--repo-root",
        root_str,
        "--host",
        "cursor",
        "--dry-run",
    ]);
    let (ss_ps, so_ps) = run_ps_script(
        "adapters/sync-skills.ps1",
        &["-RepoRoot", root_str, "-HostName", "cursor", "-DryRun"],
    );
    assert_eq!(ss_rust, 0, "{so_rust}");
    assert_eq!(ss_ps, ss_rust);
    assert_eq!(
        replace_path_variants(so_ps, &root, "<ROOT>"),
        replace_path_variants(so_rust, &root, "<ROOT>")
    );

    // install-global.ps1 -DryRun
    let fake_home = tmp.path.join("home");
    fs::create_dir_all(&fake_home).unwrap();
    let home_str = fake_home.to_str().unwrap();
    let (ig_rust, igo_rust, _) = common::run_b3_with_env(
        &[
            "install",
            "global",
            "--action",
            "install",
            "--host",
            "cursor",
            "--dry-run",
        ],
        &[("USERPROFILE", home_str), ("HOME", home_str)],
    );
    let (ig_ps, igo_ps) = run_ps_script_env(
        "adapters/install-global.ps1",
        &["-Action", "install", "-Host", "cursor", "-DryRun"],
        &[("USERPROFILE", home_str), ("HOME", home_str)],
    );
    assert_eq!(ig_rust, 0);
    assert_eq!(ig_ps, ig_rust);
    assert_eq!(
        replace_path_variants(igo_ps, &fake_home, "<HOME>"),
        replace_path_variants(igo_rust, &fake_home, "<HOME>")
    );
}
