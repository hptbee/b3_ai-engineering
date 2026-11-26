#![cfg(windows)]
//! Windows thin-wrapper argument-forwarding regression tests.
//! Validates that `scripts/*.ps1` and `adapters/*.ps1` forward arguments,
//! exit codes, and outputs cleanly to `b3.exe` (does NOT serve as an
//! independent legacy oracle; see `tests/native_golden_parity.rs`).
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU64, Ordering};

static TEST_SEQ: AtomicU64 = AtomicU64::new(0);

fn b3_bin() -> &'static str {
    env!("CARGO_BIN_EXE_b3")
}

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

struct TempDirGuard {
    path: PathBuf,
}

impl TempDirGuard {
    fn new(prefix: &str) -> Self {
        let seq = TEST_SEQ.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!(
            "b3-rust-test-{prefix}-{}-{seq}",
            std::process::id()
        ));
        if dir.exists() {
            let _ = fs::remove_dir_all(&dir);
        }
        fs::create_dir_all(&dir).expect("create temp dir");
        Self { path: dir }
    }
}

impl Drop for TempDirGuard {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

fn norm_lf(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes)
        .replace("\r\n", "\n")
        .trim_end_matches('\n')
        .to_string()
}

fn replace_path_variants(mut s: String, path: &Path, forward_slash: bool, token: &str) -> String {
    let long = b3::fs::expand_windows_long_path(path);
    let long_s = if forward_slash {
        long.to_string_lossy().replace('\\', "/")
    } else {
        long.to_string_lossy().into_owned()
    };
    let raw_s = if forward_slash {
        path.to_string_lossy().replace('\\', "/")
    } else {
        path.to_string_lossy().into_owned()
    };
    if !long_s.is_empty() {
        s = s.replace(&long_s, token);
    }
    if !raw_s.is_empty() && raw_s != long_s {
        s = s.replace(&raw_s, token);
    }
    s
}

fn replace_path_both(s: String, path: &Path, token: &str) -> String {
    replace_path_variants(s, path, false, token)
}

fn replace_path_fwd_both(s: String, path: &Path, token: &str) -> String {
    replace_path_variants(s, path, true, token)
}

fn run_b3(args: &[&str]) -> (i32, String) {
    let out = Command::new(b3_bin())
        .args(args)
        .output()
        .expect("run b3 binary");
    (out.status.code().unwrap_or(-1), norm_lf(&out.stdout))
}

fn resolve_powershell_bin() -> &'static str {
    "powershell"
}

fn run_ps_script(script_rel: &str, args: &[&str]) -> (i32, String) {
    let script = repo_root().join(script_rel);
    let out: Output = Command::new(resolve_powershell_bin())
        .env("B3_BIN", b3_bin())
        .arg("-NoProfile")
        .arg("-ExecutionPolicy")
        .arg("Bypass")
        .arg("-File")
        .arg(script)
        .args(args)
        .output()
        .expect("run powershell script");
    (out.status.code().unwrap_or(-1), norm_lf(&out.stdout))
}

fn git_in(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .expect("run git");
    assert!(
        out.status.success(),
        "git {:?} failed: {}",
        args,
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

fn init_git_repo(dir: &Path) -> String {
    let out = Command::new("git")
        .arg("init")
        .arg(dir)
        .output()
        .expect("git init");
    assert!(out.status.success(), "git init failed");
    git_in(dir, &["config", "user.email", "test@example.com"]);
    git_in(dir, &["config", "user.name", "Test"]);
    fs::create_dir_all(dir.join("src")).unwrap();
    fs::create_dir_all(dir.join("docs")).unwrap();
    fs::write(dir.join("src/app.txt"), "v1\n").unwrap();
    fs::write(dir.join("docs/guide.md"), "doc v1\n").unwrap();
    git_in(dir, &["add", "."]);
    git_in(dir, &["commit", "-m", "initial"]);
    git_in(dir, &["rev-parse", "HEAD"])
}

#[test]
fn wrapper_forwarding_context_measure_strict_matches_powershell() {
    let root = repo_root();
    let root_str = root.to_str().unwrap();
    let (rust_code, rust_out) =
        run_b3(&["context", "measure", "--repo-root", root_str, "--strict"]);
    let (ps_code, ps_out) = run_ps_script(
        "scripts/measure-context.ps1",
        &["-RepoRoot", root_str, "-Strict"],
    );
    assert_eq!(rust_code, 0);
    assert_eq!(ps_code, 0);
    assert_eq!(rust_out, ps_out);
}

#[test]
fn wrapper_forwarding_fingerprint_matches_powershell() {
    let (r_code, r_out) = run_b3(&[
        "guard",
        "fingerprint",
        "--depends-on",
        "[T003, T001, none, T002]",
        "--scope",
        "  core guard  ",
        "--criteria",
        "c1; c2",
        "--criteria",
        "c3",
    ]);
    let (p_code, p_out) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "fingerprint",
            "-DependsOn",
            "[T003, T001, none, T002]",
            "-Scope",
            "  core guard  ",
            "-Criteria",
            "c1; c2; c3",
        ],
    );
    assert_eq!(r_code, 0);
    assert_eq!(p_code, 0);
    assert_eq!(r_out, p_out);
    assert_eq!(
        r_out,
        "depends_on=T001,T002,T003|scope=core guard|acceptance_criteria=c1; c2; c3"
    );

    let (r_empty_code, r_empty_out) = run_b3(&[
        "guard",
        "fingerprint",
        "--scope",
        "s",
        "--criteria",
        "only one",
    ]);
    assert_eq!(r_empty_code, 0);
    assert_eq!(
        r_empty_out,
        "depends_on=[]|scope=s|acceptance_criteria=only one"
    );

    let (r_err_code, r_err_out) = run_b3(&["guard", "fingerprint", "--criteria", "c1"]);
    assert_eq!(r_err_code, 1);
    assert!(r_err_out.starts_with("FINGERPRINT_FAIL:"));

    let (r_err2_code, r_err2_out) = run_b3(&["guard", "fingerprint", "--scope", "s"]);
    assert_eq!(r_err2_code, 1);
    assert!(r_err2_out.starts_with("FINGERPRINT_FAIL:"));
}

#[test]
fn wrapper_forwarding_snapshot_matches_powershell_trees() {
    let tmp = TempDirGuard::new("snapshot");
    let root = &tmp.path;
    let head_sha = init_git_repo(root);
    let root_str = root.to_str().unwrap();

    // Clean tree -> exact HEAD
    let (r_clean_code, r_clean_sha) = run_b3(&["guard", "snapshot", "--repo-root", root_str]);
    let (p_clean_code, p_clean_sha) =
        run_ps_script("scripts/b3-guard.ps1", &["snapshot", "-RepoRoot", root_str]);
    assert_eq!(r_clean_code, 0);
    assert_eq!(p_clean_code, 0);
    assert_eq!(r_clean_sha, head_sha);
    assert_eq!(p_clean_sha, head_sha);

    // Dirty tracked + untracked + .b3 checkpoint dir (checkpoint must be excluded)
    fs::write(root.join("src/app.txt"), "v2\n").unwrap();
    fs::write(root.join("src/new file.txt"), "untracked\n").unwrap();
    fs::create_dir_all(root.join(".b3/ship")).unwrap();
    fs::write(root.join(".b3/ship/state.md"), "checkpoint\n").unwrap();

    let (r_dirty_code, r_dirty_sha) = run_b3(&["guard", "snapshot", "--repo-root", root_str]);
    let (p_dirty_code, p_dirty_sha) =
        run_ps_script("scripts/b3-guard.ps1", &["snapshot", "-RepoRoot", root_str]);
    assert_eq!(r_dirty_code, 0);
    assert_eq!(p_dirty_code, 0);
    assert_ne!(r_dirty_sha, head_sha);

    let r_tree = git_in(root, &["rev-parse", &format!("{r_dirty_sha}^{{tree}}")]);
    let p_tree = git_in(root, &["rev-parse", &format!("{p_dirty_sha}^{{tree}}")]);
    assert_eq!(r_tree, p_tree);

    let listed = git_in(root, &["ls-tree", "-r", "--name-only", &r_dirty_sha]);
    assert!(!listed.contains(".b3/"));
    assert!(listed.contains("src/new file.txt"));

    // Sensitive file must fail closed
    fs::write(root.join(".env"), "SECRET=1\n").unwrap();
    let (r_sec_code, r_sec_out) = run_b3(&["guard", "snapshot", "--repo-root", root_str]);
    let (p_sec_code, p_sec_out) =
        run_ps_script("scripts/b3-guard.ps1", &["snapshot", "-RepoRoot", root_str]);
    assert_eq!(r_sec_code, 1);
    assert_eq!(p_sec_code, 1);
    assert_eq!(r_sec_out, p_sec_out);
}

#[test]
fn wrapper_forwarding_check_freshness_matches_powershell() {
    let tmp = TempDirGuard::new("freshness");
    let root = &tmp.path;
    let base_sha = init_git_repo(root);
    let root_str = root.to_str().unwrap();

    // Clean -> FRESH
    let (r_code, r_out) = run_b3(&[
        "guard",
        "check-freshness",
        "--repo-root",
        root_str,
        "--approach-at-sha",
        &base_sha,
        "--task-base-sha",
        &base_sha,
        "--watched-paths",
        "src,docs",
        "--owned-files",
        "src",
    ]);
    let (p_code, p_out) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "check-freshness",
            "-RepoRoot",
            root_str,
            "-ApproachAtSha",
            &base_sha,
            "-TaskBaseSha",
            &base_sha,
            "-WatchedPaths",
            "src,docs",
            "-OwnedFiles",
            "src",
        ],
    );
    assert_eq!(r_code, 0);
    assert_eq!(p_code, 0);
    assert_eq!(r_out, "FRESH");
    assert_eq!(p_out, "FRESH");

    // Ignored dirty file in read-only dep -> still FRESH
    fs::write(root.join("docs/ignored.md"), "wip\n").unwrap();
    let (r_ign_code, r_ign_out) = run_b3(&[
        "guard",
        "check-freshness",
        "--repo-root",
        root_str,
        "--approach-at-sha",
        &base_sha,
        "--task-base-sha",
        &base_sha,
        "--watched-paths",
        "src,docs",
        "--owned-files",
        "src",
        "--ignore-dirty-paths",
        "docs/ignored.md",
    ]);
    assert_eq!(r_ign_code, 0);
    assert_eq!(r_ign_out, "FRESH");
    fs::remove_file(root.join("docs/ignored.md")).unwrap();

    // Uncommitted change in read-only watched path with space + Unicode -> STALE (exit 2)
    fs::write(root.join("docs/my file 🚀.md"), "dirty\n").unwrap();
    let (r_ro_code, r_ro_out) = run_b3(&[
        "guard",
        "check-freshness",
        "--repo-root",
        root_str,
        "--approach-at-sha",
        &base_sha,
        "--task-base-sha",
        &base_sha,
        "--watched-paths",
        "src,docs",
        "--owned-files",
        "src",
    ]);
    let (p_ro_code, p_ro_out) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "check-freshness",
            "-RepoRoot",
            root_str,
            "-ApproachAtSha",
            &base_sha,
            "-TaskBaseSha",
            &base_sha,
            "-WatchedPaths",
            "src,docs",
            "-OwnedFiles",
            "src",
        ],
    );
    assert_eq!(r_ro_code, 2);
    assert_eq!(p_ro_code, 2);
    assert_eq!(r_ro_out, p_ro_out);

    // Commit watched change -> STALE committed (exit 2)
    git_in(root, &["add", "--", "docs/my file 🚀.md"]);
    git_in(root, &["commit", "-m", "watched change"]);
    let (r_com_code, r_com_out) = run_b3(&[
        "guard",
        "check-freshness",
        "--repo-root",
        root_str,
        "--approach-at-sha",
        &base_sha,
        "--task-base-sha",
        &base_sha,
        "--watched-paths",
        "docs",
    ]);
    let (p_com_code, p_com_out) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "check-freshness",
            "-RepoRoot",
            root_str,
            "-ApproachAtSha",
            &base_sha,
            "-TaskBaseSha",
            &base_sha,
            "-WatchedPaths",
            "docs",
        ],
    );
    assert_eq!(r_com_code, 2);
    assert_eq!(p_com_code, 2);
    assert_eq!(r_com_out, p_com_out);

    // Non-ancestor task_base (orphan branch) -> STALE (exit 2)
    git_in(root, &["checkout", "--orphan", "other"]);
    fs::write(root.join("src/orphan.txt"), "x\n").unwrap();
    git_in(root, &["add", "src/orphan.txt"]);
    git_in(root, &["commit", "-m", "orphan"]);
    let (r_anc_code, r_anc_out) = run_b3(&[
        "guard",
        "check-freshness",
        "--repo-root",
        root_str,
        "--approach-at-sha",
        &base_sha,
        "--task-base-sha",
        &base_sha,
        "--watched-paths",
        "src",
    ]);
    let (p_anc_code, p_anc_out) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "check-freshness",
            "-RepoRoot",
            root_str,
            "-ApproachAtSha",
            &base_sha,
            "-TaskBaseSha",
            &base_sha,
            "-WatchedPaths",
            "src",
        ],
    );
    assert_eq!(r_anc_code, 2);
    assert_eq!(p_anc_code, 2);
    assert_eq!(r_anc_out, p_anc_out);
}

#[test]
fn wrapper_forwarding_runs_lifecycle_and_link_guards() {
    let tmp = TempDirGuard::new("runs");
    let root = &tmp.path;
    let root_str = root.to_str().unwrap();

    // Empty repo -> NO_ACTIVE_RUN and NO_RUNS
    let (r_res0, r_res0_out) = run_b3(&["guard", "resolve-run", "--repo-root", root_str]);
    let (p_res0, p_res0_out) = run_ps_script(
        "scripts/b3-guard.ps1",
        &["resolve-run", "-RepoRoot", root_str],
    );
    assert_eq!(r_res0, 1);
    assert_eq!(p_res0, 1);
    assert_eq!(r_res0_out, "NO_ACTIVE_RUN");
    assert_eq!(p_res0_out, "NO_ACTIVE_RUN");

    let (r_list0, r_list0_out) = run_b3(&["guard", "list-runs", "--repo-root", root_str]);
    let (p_list0, p_list0_out) = run_ps_script(
        "scripts/b3-guard.ps1",
        &["list-runs", "-RepoRoot", root_str],
    );
    assert_eq!(r_list0, 0);
    assert_eq!(p_list0, 0);
    assert_eq!(r_list0_out, "NO_RUNS");
    assert_eq!(p_list0_out, "NO_RUNS");

    // new-run slug sanitization & collision suffix -2 / -3
    let (c1, id1) = run_b3(&[
        "guard",
        "new-run",
        "--repo-root",
        root_str,
        "--slug",
        "My Feature!! 123",
        "--timestamp",
        "20261126-1000",
    ]);
    assert_eq!(c1, 0);
    assert_eq!(id1, "20261126-1000-my-feature-123");

    let cur_bytes = fs::read(root.join(".b3/ship/CURRENT")).unwrap();
    assert!(!cur_bytes.contains(&b'\r'));
    assert!(cur_bytes.ends_with(b"\n"));

    let (c2, id2) = run_b3(&[
        "guard",
        "new-run",
        "--repo-root",
        root_str,
        "--slug",
        "My Feature!! 123",
        "--timestamp",
        "20261126-1000",
    ]);
    assert_eq!(c2, 0);
    assert_eq!(id2, "20261126-1000-my-feature-123-2");

    let (c3, id3) = run_b3(&[
        "guard",
        "new-run",
        "--repo-root",
        root_str,
        "--slug",
        "My Feature!! 123",
        "--timestamp",
        "20261126-1001",
    ]);
    assert_eq!(c3, 0);
    assert_eq!(id3, "20261126-1001-my-feature-123");

    // Mark id1, id2, id3 as PASS; create one non-PASS run id4
    for id in [&id1, &id2, &id3] {
        fs::write(
            root.join(".b3/ship/runs").join(id).join("progress.md"),
            "- run_status: PASS\n",
        )
        .unwrap();
    }
    let (_, id4) = run_b3(&[
        "guard",
        "new-run",
        "--repo-root",
        root_str,
        "--slug",
        "active-wip",
        "--timestamp",
        "20261126-1002",
    ]);
    fs::write(
        root.join(".b3/ship/runs").join(&id4).join("progress.md"),
        "- run_status: IN_PROGRESS\n",
    )
    .unwrap();

    // resolve-run and list-runs parity with PS
    let (r_res_c, r_res_o) = run_b3(&["guard", "resolve-run", "--repo-root", root_str]);
    let (p_res_c, p_res_o) = run_ps_script(
        "scripts/b3-guard.ps1",
        &["resolve-run", "-RepoRoot", root_str],
    );
    assert_eq!(r_res_c, p_res_c);
    assert_eq!(r_res_o, p_res_o);

    let (r_list_c, r_list_o) = run_b3(&["guard", "list-runs", "--repo-root", root_str]);
    let (p_list_c, p_list_o) = run_ps_script(
        "scripts/b3-guard.ps1",
        &["list-runs", "-RepoRoot", root_str],
    );
    assert_eq!(r_list_c, p_list_c);
    assert_eq!(r_list_o, p_list_o);

    // prune --keep 1 keeps newest PASS (id3) + IN_PROGRESS (id4), removes id2 and id1
    let (r_pr_c, r_pr_o) = run_b3(&["guard", "prune", "--repo-root", root_str, "--keep", "1"]);
    assert_eq!(r_pr_c, 0);
    assert!(r_pr_o.contains(&format!("pruned: {id2}")));
    assert!(r_pr_o.contains(&format!("pruned: {id1}")));
    assert!(r_pr_o.contains("PRUNE_OK: 2 removed"));
    assert!(root.join(".b3/ship/runs").join(&id3).is_dir());
    assert!(root.join(".b3/ship/runs").join(&id4).is_dir());
    assert!(!root.join(".b3/ship/runs").join(&id1).exists());
    assert!(!root.join(".b3/ship/runs").join(&id2).exists());

    // research-ship namespace isolation
    let (rs_c, rs_id) = run_b3(&[
        "guard",
        "new-run",
        "--repo-root",
        root_str,
        "--namespace",
        "research-ship",
        "--slug",
        "topic",
        "--timestamp",
        "20261126-1005",
    ]);
    assert_eq!(rs_c, 0);
    let (rs_res_c, rs_res_o) = run_b3(&[
        "guard",
        "resolve-run",
        "--repo-root",
        root_str,
        "--namespace",
        "research-ship",
    ]);
    assert_eq!(rs_res_c, 0);
    assert_eq!(rs_res_o, format!(".b3/research-ship/runs/{rs_id}"));

    // legacy .b3/autodev fallback
    let ad_tmp = TempDirGuard::new("autodev");
    let ad_root = &ad_tmp.path;
    let ad_str = ad_root.to_str().unwrap();
    fs::create_dir_all(ad_root.join(".b3/autodev/runs/20260101-0101-old")).unwrap();
    fs::write(ad_root.join(".b3/autodev/CURRENT"), "20260101-0101-old\n").unwrap();
    let (ad_r_c, ad_r_o) = run_b3(&["guard", "resolve-run", "--repo-root", ad_str]);
    let (ad_p_c, ad_p_o) = run_ps_script(
        "scripts/b3-guard.ps1",
        &["resolve-run", "-RepoRoot", ad_str],
    );
    assert_eq!(ad_r_c, ad_p_c);
    assert_eq!(ad_r_o, ad_p_o);
    assert_eq!(ad_r_o, ".b3/autodev/runs/20260101-0101-old");

    // Link / junction rejection on Windows
    #[cfg(windows)]
    {
        let link_tmp = TempDirGuard::new("linkguard");
        let link_root = &link_tmp.path;
        let target_dir = link_root.join("outside");
        fs::create_dir_all(&target_dir).unwrap();
        let dot_b3 = link_root.join(".b3");
        let mk = Command::new("powershell")
            .args([
                "-NoProfile",
                "-Command",
                &format!(
                    "New-Item -ItemType Junction -Path '{}' -Target '{}' | Out-Null",
                    dot_b3.display(),
                    target_dir.display()
                ),
            ])
            .output()
            .expect("create junction");
        assert!(mk.status.success(), "junction setup failed");
        let lr_str = link_root.to_str().unwrap();

        let (lc1, lo1) = run_b3(&["guard", "resolve-run", "--repo-root", lr_str]);
        let (pc1, po1) = run_ps_script(
            "scripts/b3-guard.ps1",
            &["resolve-run", "-RepoRoot", lr_str],
        );
        assert_eq!(lc1, 1);
        assert_eq!(pc1, 1);
        assert_eq!(lo1, "RESOLVE_FAIL: runs directory is a link");
        assert_eq!(lo1, po1);

        let (lc2, lo2) = run_b3(&["guard", "prune", "--repo-root", lr_str]);
        assert_eq!(lc2, 1);
        assert_eq!(lo2, "PRUNE_FAIL: runs directory is a link");

        // Nested NTFS directory junction inside a PASS run being pruned must be unlinked without traversing target
        let nested_tmp = TempDirGuard::new("nestedjunc");
        let nroot = &nested_tmp.path;
        let nr_str = nroot.to_str().unwrap();
        let decoy_target = nroot.join("decoy-outside");
        fs::create_dir_all(&decoy_target).unwrap();
        fs::write(decoy_target.join("keep.txt"), "safe\n").unwrap();
        let (_, old_id) = run_b3(&[
            "guard",
            "new-run",
            "--repo-root",
            nr_str,
            "--slug",
            "old",
            "--timestamp",
            "20261126-0900",
        ]);
        let old_dir = nroot.join(".b3/ship/runs").join(&old_id);
        fs::write(old_dir.join("progress.md"), "- run_status: PASS\n").unwrap();
        let (_, cur_id) = run_b3(&[
            "guard",
            "new-run",
            "--repo-root",
            nr_str,
            "--slug",
            "cur",
            "--timestamp",
            "20261126-0901",
        ]);
        fs::write(
            nroot
                .join(".b3/ship/runs")
                .join(&cur_id)
                .join("progress.md"),
            "- run_status: PASS\n",
        )
        .unwrap();
        let nested_junc = old_dir.join("nested-junc");
        let mk_nj = Command::new("powershell")
            .args([
                "-NoProfile",
                "-Command",
                &format!(
                    "New-Item -ItemType Junction -Path '{}' -Target '{}' | Out-Null",
                    nested_junc.display(),
                    decoy_target.display()
                ),
            ])
            .output()
            .expect("create nested junction");
        assert!(mk_nj.status.success(), "nested junction setup failed");

        let (npr_c, npr_o) = run_b3(&["guard", "prune", "--repo-root", nr_str, "--keep", "1"]);
        assert_eq!(npr_c, 0, "prune with nested junction failed: {npr_o}");
        assert!(npr_o.contains("PRUNE_OK: 1 removed"));
        assert!(!old_dir.exists());
        assert!(decoy_target.join("keep.txt").is_file());
    }
}

#[test]
fn wrapper_forwarding_verify_run_and_verify_check_match_powershell() {
    let tmp = TempDirGuard::new("verify");
    let root = &tmp.path;
    let head_sha = init_git_repo(root);
    let root_str = root.to_str().unwrap();

    // Passing verify-run (scoped) compared against PS legacy tree_hash
    fs::write(root.join("src/app.txt"), "v2\n").unwrap();
    fs::write(root.join("src/extra.txt"), "untracked\n").unwrap();
    fs::write(root.join("docs/ignored.md"), "ignored\n").unwrap();

    let (r_c, r_o) = run_b3(&[
        "guard",
        "verify-run",
        "--repo-root",
        root_str,
        "--verify-cmd",
        "Write-Output 'ok'",
        "--receipt-path",
        ".b3/ship/r-rust.txt",
        "--task-id",
        "T001",
        "--scope",
        "src",
        "--relevant-paths",
        "src",
        "--ignore-dirty-paths",
        "docs/ignored.md",
    ]);
    let (p_c, p_o) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "verify-run",
            "-RepoRoot",
            root_str,
            "-VerifyCmd",
            "Write-Output 'ok'",
            "-ReceiptPath",
            ".b3/ship/r-ps.txt",
            "-TaskId",
            "T001",
            "-Scope",
            "src",
            "-RelevantPaths",
            "src",
            "-IgnoreDirtyPaths",
            "docs/ignored.md",
        ],
    );
    assert_eq!(r_c, 0);
    assert_eq!(p_c, 0);
    assert!(r_o.starts_with("VERIFY_PASS: exit=0 tree="));
    assert!(p_o.starts_with("VERIFY_PASS: exit=0 tree="));

    let rust_rec = fs::read_to_string(root.join(".b3/ship/r-rust.txt")).unwrap();
    let ps_rec = fs::read_to_string(root.join(".b3/ship/r-ps.txt")).unwrap();
    let extract = |txt: &str, key: &str| -> String {
        txt.lines()
            .find_map(|l| l.strip_prefix(&format!("{key}=")))
            .unwrap()
            .to_string()
    };
    assert_eq!(extract(&rust_rec, "schema"), "b3-verify-v1");
    assert_eq!(extract(&rust_rec, "head_sha"), head_sha);
    assert_eq!(
        extract(&rust_rec, "tree_hash"),
        extract(&ps_rec, "tree_hash")
    );
    assert_eq!(extract(&rust_rec, "relevant_paths"), "src");
    assert_eq!(extract(&rust_rec, "log_path"), "none");

    // Cross-validate receipt: Rust verify-check passes PS receipt and vice versa
    let (chk_rc, chk_ro) = run_b3(&[
        "guard",
        "verify-check",
        "--repo-root",
        root_str,
        "--receipt-path",
        ".b3/ship/r-ps.txt",
        "--expected-cmd",
        "Write-Output 'ok'",
        "--relevant-paths",
        "src",
        "--ignore-dirty-paths",
        "docs/ignored.md",
    ]);
    assert_eq!(chk_rc, 0);
    assert!(chk_ro.starts_with("VERIFY_VALID: task=T001 scope=src tree="));

    // Empty --target-commit-sha rejected fail-closed
    let (emp_c, emp_o) = run_b3(&[
        "guard",
        "verify-check",
        "--repo-root",
        root_str,
        "--receipt-path",
        ".b3/ship/r-rust.txt",
        "--target-commit-sha",
        "   ",
    ]);
    assert_eq!(emp_c, 1);
    assert_eq!(emp_o, "VERIFY_CHECK_FAIL: empty --target-commit-sha");

    // Command mismatch and uncovered path mismatch
    let (mm_c, mm_o) = run_b3(&[
        "guard",
        "verify-check",
        "--repo-root",
        root_str,
        "--receipt-path",
        ".b3/ship/r-rust.txt",
        "--expected-cmd",
        "other-cmd",
    ]);
    assert_eq!(mm_c, 1);
    assert_eq!(mm_o, "VERIFY_MISMATCH: command mismatch");

    // Target commit check on HEAD fails against dirty working-tree receipt, passes after commit of clean tree
    let (t_c, t_o) = run_b3(&[
        "guard",
        "verify-check",
        "--repo-root",
        root_str,
        "--receipt-path",
        ".b3/ship/r-rust.txt",
        "--target-commit-sha",
        &head_sha,
    ]);
    assert_eq!(t_c, 2);
    assert!(t_o.starts_with("VERIFY_STALE:"));

    // Modify file in scope -> VERIFY_STALE (exit 2) matching PS
    fs::write(root.join("src/app.txt"), "v3\n").unwrap();
    let (st_rc, st_ro) = run_b3(&[
        "guard",
        "verify-check",
        "--repo-root",
        root_str,
        "--receipt-path",
        ".b3/ship/r-rust.txt",
    ]);
    let (st_pc, st_po) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "verify-check",
            "-RepoRoot",
            root_str,
            "-ReceiptPath",
            ".b3/ship/r-rust.txt",
        ],
    );
    assert_eq!(st_rc, 2);
    assert_eq!(st_pc, 2);
    assert_eq!(st_ro, st_po);

    // Failing verify-run writes log file and exits 1
    let (fail_c, fail_o) = run_b3(&[
        "guard",
        "verify-run",
        "--repo-root",
        root_str,
        "--verify-cmd",
        "Write-Output 'boom'; exit 3",
        "--receipt-path",
        ".b3/ship/r-fail.txt",
    ]);
    assert_eq!(fail_c, 1);
    assert!(fail_o.starts_with("VERIFY_FAIL: exit=3 tree="));
    assert!(fail_o.contains("boom"));
    assert!(root.join(".b3/ship/r-fail.txt.log").is_file());

    // Wrapper verify-run preserves inner quotes when forwarding through PowerShell 5.1
    let wrapper_ps1 = repo_root().join("scripts/b3-guard.ps1");
    let wrap_out = Command::new("powershell")
        .env("B3_BIN", b3_bin())
        .arg("-NoProfile")
        .arg("-ExecutionPolicy")
        .arg("Bypass")
        .arg("-File")
        .arg(&wrapper_ps1)
        .args([
            "verify-run",
            "-RepoRoot",
            root_str,
            "-VerifyCmd",
            "1..40 | ForEach-Object { \"line-$_\" }",
            "-ReceiptPath",
            ".b3/ship/r-wrap.txt",
        ])
        .output()
        .expect("run wrapper verify-run");
    assert_eq!(wrap_out.status.code(), Some(0));
    let wrap_rec = fs::read_to_string(root.join(".b3/ship/r-wrap.txt")).unwrap();
    assert_eq!(extract(&wrap_rec, "log_path"), ".b3/ship/r-wrap.txt.log");
}

#[test]
fn wrapper_forwarding_precommit_matches_powershell() {
    let tmp = TempDirGuard::new("precommit");
    let root = &tmp.path;
    let _head = init_git_repo(root);
    let root_str = root.to_str().unwrap();

    // Nothing staged
    let (r0, ro0) = run_b3(&["guard", "precommit", "--repo-root", root_str]);
    let (p0, po0) = run_ps_script(
        "scripts/b3-guard.ps1",
        &["precommit", "-RepoRoot", root_str],
    );
    assert_eq!(r0, 1);
    assert_eq!(p0, 1);
    assert_eq!(ro0, "PRECOMMIT_FAIL: nothing staged");
    assert_eq!(ro0, po0);

    // Stage allowed file and undeclared file
    fs::write(root.join("src/app.txt"), "v2\n").unwrap();
    fs::write(root.join("docs/guide.md"), "doc v2\n").unwrap();
    git_in(root, &["add", "src/app.txt", "docs/guide.md"]);

    let (ru, ruo) = run_b3(&[
        "guard",
        "precommit",
        "--repo-root",
        root_str,
        "--allowed-paths",
        "src",
    ]);
    let (pu, puo) = run_ps_script(
        "scripts/b3-guard.ps1",
        &["precommit", "-RepoRoot", root_str, "-AllowedPaths", "src"],
    );
    assert_eq!(ru, 1);
    assert_eq!(pu, 1);
    assert_eq!(ruo, puo);

    // Unstage docs/guide.md, verify receipt, check precommit --require-verify-receipt
    git_in(root, &["reset", "-q", "HEAD", "--", "docs/guide.md"]);
    let (vc, _) = run_b3(&[
        "guard",
        "verify-run",
        "--repo-root",
        root_str,
        "--verify-cmd",
        "exit 0",
        "--receipt-path",
        ".b3/ship/precommit-rec.txt",
        "--relevant-paths",
        "src",
    ]);
    assert_eq!(vc, 0);

    let (rp_c, rp_o) = run_b3(&[
        "guard",
        "precommit",
        "--repo-root",
        root_str,
        "--allowed-paths",
        "src",
        "--require-verify-receipt",
        ".b3/ship/precommit-rec.txt",
    ]);
    let (pp_c, pp_o) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "precommit",
            "-RepoRoot",
            root_str,
            "-AllowedPaths",
            "src",
            "-RequireVerifyReceipt",
            ".b3/ship/precommit-rec.txt",
        ],
    );
    assert_eq!(rp_c, 0);
    assert_eq!(pp_c, 0);
    assert_eq!(rp_o, "PRECOMMIT_OK");
    assert_eq!(pp_o, "PRECOMMIT_OK");

    // Secret file without exact allow rejected
    fs::write(root.join(".env"), "KEY=val\n").unwrap();
    git_in(root, &["add", "-f", ".env"]);
    let (rs_c, rs_o) = run_b3(&[
        "guard",
        "precommit",
        "--repo-root",
        root_str,
        "--allowed-paths",
        ".,src",
    ]);
    let (ps_c, ps_o) = run_ps_script(
        "scripts/b3-guard.ps1",
        &["precommit", "-RepoRoot", root_str, "-AllowedPaths", ".,src"],
    );
    assert_eq!(rs_c, 1);
    assert_eq!(ps_c, 1);
    assert_eq!(rs_o, ps_o);
}

#[test]
fn wrapper_forwarding_check_worktree_matches_powershell() {
    let tmp = TempDirGuard::new("worktree");
    let main_repo = tmp.path.join("main");
    let linked_wt = tmp.path.join("wt-worker");
    let wt2 = tmp.path.join("wt-peer");
    fs::create_dir_all(&main_repo).unwrap();
    let head_sha = init_git_repo(&main_repo);
    git_in(
        &main_repo,
        &["worktree", "add", "-b", "w1", linked_wt.to_str().unwrap()],
    );
    git_in(
        &main_repo,
        &["worktree", "add", "-b", "w2", wt2.to_str().unwrap()],
    );

    let main_str = main_repo.to_str().unwrap();
    let linked_str = linked_wt.to_str().unwrap();
    let wt2_str = wt2.to_str().unwrap();

    // Valid isolated linked worktree with peer
    let (rc, ro) = run_b3(&[
        "guard",
        "check-worktree",
        "--repo-root",
        linked_str,
        "--expected-root",
        main_str,
        "--expected-base-sha",
        &head_sha,
        "--peer-roots",
        wt2_str,
        "--require-isolated",
    ]);
    let (pc, po) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "check-worktree",
            "-RepoRoot",
            linked_str,
            "-ExpectedRoot",
            main_str,
            "-ExpectedBaseSha",
            &head_sha,
            "-PeerRoots",
            wt2_str,
            "-RequireIsolated",
        ],
    );
    assert_eq!(rc, 0);
    assert_eq!(pc, 0);
    assert_eq!(ro, po);
    assert!(ro.contains("linked=true isolated=true"));

    // Parent root reused when --require-isolated is set -> exit 2 parity
    let (r_bad, ro_bad) = run_b3(&[
        "guard",
        "check-worktree",
        "--repo-root",
        main_str,
        "--expected-root",
        main_str,
        "--require-isolated",
    ]);
    let (p_bad, po_bad) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "check-worktree",
            "-RepoRoot",
            main_str,
            "-ExpectedRoot",
            main_str,
            "-RequireIsolated",
        ],
    );
    assert_eq!(r_bad, 2);
    assert_eq!(p_bad, 2);
    assert_eq!(ro_bad, po_bad);

    // Base SHA mismatch -> exit 2 parity
    let (r_bm, ro_bm) = run_b3(&[
        "guard",
        "check-worktree",
        "--repo-root",
        linked_str,
        "--expected-base-sha",
        "0000000000000000000000000000000000000000",
    ]);
    let (p_bm, po_bm) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "check-worktree",
            "-RepoRoot",
            linked_str,
            "-ExpectedBaseSha",
            "0000000000000000000000000000000000000000",
        ],
    );
    assert_eq!(r_bm, 2);
    assert_eq!(p_bm, 2);
    assert_eq!(ro_bm, po_bm);

    // Duplicate peer root -> exit 2 parity
    let (r_dup, ro_dup) = run_b3(&[
        "guard",
        "check-worktree",
        "--repo-root",
        linked_str,
        "--peer-roots",
        linked_str,
    ]);
    let (p_dup, po_dup) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "check-worktree",
            "-RepoRoot",
            linked_str,
            "-PeerRoots",
            linked_str,
        ],
    );
    assert_eq!(r_dup, 2);
    assert_eq!(p_dup, 2);
    assert_eq!(ro_dup, po_dup);
}

#[test]
fn wrapper_forwarding_check_wave_matches_powershell() {
    let tmp = TempDirGuard::new("wave");
    let root = &tmp.path;
    let base_sha = init_git_repo(root);
    fs::create_dir_all(root.join("api")).unwrap();
    fs::create_dir_all(root.join("ui")).unwrap();
    fs::write(root.join("api/a.ts"), "export const a = 1;\n").unwrap();
    fs::write(root.join("ui/b.tsx"), "export const b = 2;\n").unwrap();
    let root_str = root.to_str().unwrap();

    // Disjoint waves -> WAVE_OK
    let (r0, ro0) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        root_str,
        "--wave-specs",
        "T001=api/a.ts;T002=ui/b.tsx",
    ]);
    let (p0, po0) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "check-wave",
            "-RepoRoot",
            root_str,
            "-WaveSpecs",
            "T001=api/a.ts;T002=ui/b.tsx",
        ],
    );
    assert_eq!(r0, 0);
    assert_eq!(p0, 0);
    assert_eq!(ro0, po0);

    // Write-write & write-read conflict -> exit 2 parity
    let (rc, roc) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        root_str,
        "--wave-specs",
        "T001=src/app.txt;T002=api/a.ts",
        "--wave-reads",
        "T002=src/app.txt",
    ]);
    let (pc, poc) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "check-wave",
            "-RepoRoot",
            root_str,
            "-WaveSpecs",
            "T001=src/app.txt;T002=api/a.ts",
            "-WaveReads",
            "T002=src/app.txt",
        ],
    );
    assert_eq!(rc, 2);
    assert_eq!(pc, 2);
    assert_eq!(roc, poc);

    // Partition with conflicts + max-concurrency=2 + protected-paths rejection
    let (rp, rop) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        root_str,
        "--wave-specs",
        "T001=api/a.ts;T002=ui/b.tsx;T003=docs/guide.md;T004=api/a.ts",
        "--partition",
        "--max-concurrency",
        "2",
    ]);
    let (pp, pop) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "check-wave",
            "-RepoRoot",
            root_str,
            "-WaveSpecs",
            "T001=api/a.ts;T002=ui/b.tsx;T003=docs/guide.md;T004=api/a.ts",
            "-Partition",
            "-MaxConcurrency",
            "2",
        ],
    );
    assert_eq!(rp, 0);
    assert_eq!(pp, 0);
    assert_eq!(rop, pop);

    let (rprot, roprot) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        root_str,
        "--wave-specs",
        "T001=docs/guide.md",
        "--protected-paths",
        "docs",
    ]);
    let (pprot, poprot) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "check-wave",
            "-RepoRoot",
            root_str,
            "-WaveSpecs",
            "T001=docs/guide.md",
            "-ProtectedPaths",
            "docs",
        ],
    );
    assert_eq!(rprot, 1);
    assert_eq!(pprot, 1);
    assert_eq!(roprot, poprot);

    // Dirty scope with ignore-dirty-paths blocking matching task only
    let (rd, rod) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        root_str,
        "--wave-specs",
        "T001=api;T002=src/app.txt",
        "--expected-base-sha",
        &base_sha,
        "--partition",
        "--check-dirty-scope",
        "--ignore-dirty-paths",
        "api,ui",
    ]);
    let (pd, pod) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "check-wave",
            "-RepoRoot",
            root_str,
            "-WaveSpecs",
            "T001=api;T002=src/app.txt",
            "-ExpectedBaseSha",
            &base_sha,
            "-Partition",
            "-CheckDirtyScope",
            "-IgnoreDirtyPaths",
            "api,ui",
        ],
    );
    assert_eq!(rd, pd);
    assert_eq!(rod, pod);
}

#[test]
fn wrapper_forwarding_symbol_check_matches_powershell() {
    let tmp = TempDirGuard::new("symbol");
    let root = &tmp.path;
    init_git_repo(root);
    fs::write(
        root.join("src/lib.ts"),
        "export function dropFn() { return 1; }\nexport function keepFn() { return 2; }\n",
    )
    .unwrap();
    fs::write(
        root.join("src/caller.ts"),
        "import { dropFn } from './lib';\nexport const x = dropFn();\n",
    )
    .unwrap();
    fs::write(
        root.join("src/mod.rs"),
        "pub fn old_rust_fn() -> i32 { 1 }\n",
    )
    .unwrap();
    fs::write(
        root.join("src/user.rs"),
        "pub fn call_it() -> i32 { crate::old_rust_fn() }\n",
    )
    .unwrap();
    git_in(root, &["add", "."]);
    git_in(root, &["commit", "-m", "add ts and rs symbols"]);
    let base_sha = git_in(root, &["rev-parse", "HEAD"]);
    let root_str = root.to_str().unwrap();

    // Remove exported TS and Rust functions while callers still reference them -> SYMBOL_FINDINGS (exit 2)
    fs::write(
        root.join("src/lib.ts"),
        "export function keepFn() { return 2; }\n",
    )
    .unwrap();
    fs::write(root.join("src/mod.rs"), "// removed\n").unwrap();

    let (rc, ro) = run_b3(&[
        "guard",
        "symbol-check",
        "--repo-root",
        root_str,
        "--base-sha",
        &base_sha,
    ]);
    let (pc, po) = run_ps_script(
        "scripts/b3-guard.ps1",
        &["symbol-check", "-RepoRoot", root_str, "-BaseSha", &base_sha],
    );
    assert_eq!(rc, 2);
    assert_eq!(pc, 2);
    assert_eq!(ro, po);

    // Update callers -> SYMBOL_OK (exit 0)
    fs::write(root.join("src/caller.ts"), "export const x = 42;\n").unwrap();
    fs::write(root.join("src/user.rs"), "pub fn call_it() -> i32 { 2 }\n").unwrap();
    let (rc_ok, ro_ok) = run_b3(&[
        "guard",
        "symbol-check",
        "--repo-root",
        root_str,
        "--base-sha",
        &base_sha,
    ]);
    let (pc_ok, po_ok) = run_ps_script(
        "scripts/b3-guard.ps1",
        &["symbol-check", "-RepoRoot", root_str, "-BaseSha", &base_sha],
    );
    assert_eq!(rc_ok, 0);
    assert_eq!(pc_ok, 0);
    assert_eq!(ro_ok, po_ok);
}

#[test]
fn wrapper_forwarding_diff_scope_matches_powershell() {
    let tmp = TempDirGuard::new("diffscope");
    let root = &tmp.path;
    let base_sha = init_git_repo(root);
    let root_str = root.to_str().unwrap();

    // Clean tree -> EMPTY_DIFF (exit 2)
    let (re, roe) = run_b3(&[
        "guard",
        "diff-scope",
        "--repo-root",
        root_str,
        "--base-sha",
        &base_sha,
    ]);
    let (pe, poe) = run_ps_script(
        "scripts/b3-guard.ps1",
        &["diff-scope", "-RepoRoot", root_str, "-BaseSha", &base_sha],
    );
    assert_eq!(re, 2);
    assert_eq!(pe, 2);
    assert_eq!(roe, poe);

    // Dirty tree with noise + code + auth risk signal
    fs::create_dir_all(root.join("src/auth")).unwrap();
    fs::write(root.join("package-lock.json"), "{}\n").unwrap();
    fs::write(
        root.join("src/auth/login.ts"),
        "export function login() { return verifyToken(); }\n",
    )
    .unwrap();
    fs::write(root.join("src/app.txt"), "v2\n").unwrap();

    let (rd, rod) = run_b3(&[
        "guard",
        "diff-scope",
        "--repo-root",
        root_str,
        "--base-sha",
        &base_sha,
    ]);
    let (pd, pod) = run_ps_script(
        "scripts/b3-guard.ps1",
        &["diff-scope", "-RepoRoot", root_str, "-BaseSha", &base_sha],
    );
    assert_eq!(rd, 0);
    assert_eq!(pd, 0);
    assert_eq!(rod, pod);

    // PrevSha delta + CLEAN_AFTER_FIX
    git_in(root, &["add", "."]);
    git_in(root, &["commit", "-m", "work"]);
    let work_sha = git_in(root, &["rev-parse", "HEAD"]);

    // Commit target-ref check
    let (rt, rot) = run_b3(&[
        "guard",
        "diff-scope",
        "--repo-root",
        root_str,
        "--base-sha",
        &base_sha,
        "--target-ref",
        &work_sha,
        "--prev-sha",
        &base_sha,
    ]);
    let (pt, pot) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "diff-scope",
            "-RepoRoot",
            root_str,
            "-BaseSha",
            &base_sha,
            "-TargetRef",
            &work_sha,
            "-PrevSha",
            &base_sha,
        ],
    );
    assert_eq!(rt, 0);
    assert_eq!(pt, 0);
    assert_eq!(rot, pot);

    // Compare work_sha vs work_sha with prev_sha=base_sha -> CLEAN_AFTER_FIX
    let (rcaf, rocaf) = run_b3(&[
        "guard",
        "diff-scope",
        "--repo-root",
        root_str,
        "--base-sha",
        &work_sha,
        "--prev-sha",
        &base_sha,
    ]);
    let (pcaf, pocaf) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "diff-scope",
            "-RepoRoot",
            root_str,
            "-BaseSha",
            &work_sha,
            "-PrevSha",
            &base_sha,
        ],
    );
    assert_eq!(rcaf, 0);
    assert_eq!(pcaf, 0);
    assert_eq!(rocaf, pocaf);
}

#[test]
fn wrapper_forwarding_mechanical_check_matches_powershell() {
    let tmp = TempDirGuard::new("mechanical");
    let root = &tmp.path;
    let base_sha = init_git_repo(root);
    let root_str = root.to_str().unwrap();

    // Clean allowed change -> MECHANICAL_OK
    fs::write(root.join("src/app.txt"), "v2\n").unwrap();
    let (r0, ro0) = run_b3(&[
        "guard",
        "mechanical-check",
        "--repo-root",
        root_str,
        "--base-sha",
        &base_sha,
        "--allowed-paths",
        "src",
    ]);
    let (p0, po0) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "mechanical-check",
            "-RepoRoot",
            root_str,
            "-BaseSha",
            &base_sha,
            "-AllowedPaths",
            "src",
        ],
    );
    assert_eq!(r0, 0);
    assert_eq!(p0, 0);
    assert_eq!(ro0, po0);

    // Scope creep + leftover + destructive SQL + protected path + worker-changes attribution -> exit 2 parity
    fs::write(
        root.join("src/bad.ts"),
        concat!(
            "// @ts-",
            "ignore\n",
            "deb",
            "ugger;\nconst sql = 'DROP TABLE users';\n"
        ),
    )
    .unwrap();
    fs::write(root.join("docs/guide.md"), "touched outside allowed\n").unwrap();

    let (rf, rof) = run_b3(&[
        "guard",
        "mechanical-check",
        "--repo-root",
        root_str,
        "--base-sha",
        &base_sha,
        "--allowed-paths",
        "src",
        "--protected-paths",
        "docs",
        "--wave-specs",
        "T001=src/app.txt;T002=src/bad.ts",
        "--worker-changes",
        "T001=src/app.txt;T002=src/bad.ts",
    ]);
    let (pf, pof) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "mechanical-check",
            "-RepoRoot",
            root_str,
            "-BaseSha",
            &base_sha,
            "-AllowedPaths",
            "src",
            "-ProtectedPaths",
            "docs",
            "-WaveSpecs",
            "T001=src/app.txt;T002=src/bad.ts",
            "-WorkerChanges",
            "T001=src/app.txt;T002=src/bad.ts",
        ],
    );
    assert_eq!(rf, 2);
    assert_eq!(pf, 2);
    assert_eq!(rof, pof);
}

#[test]
fn wrapper_forwarding_review_inventory_matches_powershell() {
    let tmp = TempDirGuard::new("rev-inv");
    let root = &tmp.path;
    let base_sha = init_git_repo(root);
    let root_str = root.to_str().unwrap();

    // Empty diff -> exit 2 parity
    let (re, roe) = run_b3(&[
        "guard",
        "review-inventory",
        "--repo-root",
        root_str,
        "--base-sha",
        &base_sha,
    ]);
    let (pe, poe) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "review-inventory",
            "-RepoRoot",
            root_str,
            "-BaseSha",
            &base_sha,
        ],
    );
    assert_eq!(re, 2);
    assert_eq!(pe, 2);
    assert_eq!(roe, poe);

    // Multi-module repo + contract + test + noise
    fs::create_dir_all(root.join("src/contracts")).unwrap();
    fs::create_dir_all(root.join("src/auth")).unwrap();
    fs::create_dir_all(root.join("src/pay")).unwrap();
    fs::create_dir_all(root.join("tests/auth")).unwrap();
    fs::write(
        root.join("src/contracts/api.ts"),
        "export interface SessionDto { id: string }\n",
    )
    .unwrap();
    fs::write(
        root.join("src/auth/login.ts"),
        "export function login(token: string) { return token.length > 0; }\n",
    )
    .unwrap();
    fs::write(
        root.join("src/pay/calc.ts"),
        "export function total(n: number) { return n * 2; }\n",
    )
    .unwrap();
    fs::write(
        root.join("tests/auth/login.test.ts"),
        "test('ok', () => expect(true).toBe(true));\n",
    )
    .unwrap();
    fs::write(root.join("package-lock.json"), "{}\n").unwrap();

    let (r1, ro1) = run_b3(&[
        "guard",
        "review-inventory",
        "--repo-root",
        root_str,
        "--base-sha",
        &base_sha,
        "--max-concurrency",
        "3",
    ]);
    let (p1, po1) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "review-inventory",
            "-RepoRoot",
            root_str,
            "-BaseSha",
            &base_sha,
            "-MaxConcurrency",
            "3",
        ],
    );
    assert_eq!(r1, 0);
    assert_eq!(p1, 0);
    assert_eq!(ro1, po1);
}

#[test]
fn wrapper_forwarding_review_ledger_lifecycle_matches_powershell() {
    let tmp = TempDirGuard::new("rev-ledger");
    let root = &tmp.path;
    let base_sha = init_git_repo(root);
    let root_str = root.to_str().unwrap();

    // Standalone normalize --scope
    let (rn0, rno0) = run_b3(&[
        "guard",
        "review-ledger",
        "--repo-root",
        root_str,
        "--action",
        "normalize",
        "--scope",
        "VERY_LARGE",
    ]);
    let (pn0, pno0) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "review-ledger",
            "-RepoRoot",
            root_str,
            "-Action",
            "normalize",
            "-Scope",
            "VERY_LARGE",
        ],
    );
    assert_eq!(rn0, 0);
    assert_eq!(pn0, 0);
    assert_eq!(rno0, "XL");
    assert_eq!(rno0, pno0);

    // Commit a code change for commit-bound review ledger lifecycle
    fs::write(root.join("src/app.txt"), "v2\nv3\n").unwrap();
    git_in(root, &["add", "src/app.txt"]);
    git_in(root, &["commit", "-q", "-m", "v2 change"]);
    let head_sha = git_in(root, &["rev-parse", "HEAD"]);

    let (ri_r, rio_r) = run_b3(&[
        "guard",
        "review-ledger",
        "--repo-root",
        root_str,
        "--action",
        "init",
        "--ledger-path",
        ".b3/ship/l-rust.md",
        "--base-sha",
        &base_sha,
        "--target-ref",
        &head_sha,
    ]);
    let (ri_p, rio_p) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "review-ledger",
            "-RepoRoot",
            root_str,
            "-Action",
            "init",
            "-LedgerPath",
            ".b3/ship/l-ps.md",
            "-BaseSha",
            &base_sha,
            "-TargetRef",
            &head_sha,
        ],
    );
    assert_eq!(ri_r, 0);
    assert_eq!(ri_p, 0);
    assert_eq!(
        rio_r.replace("l-rust.md", "L"),
        rio_p.replace("l-ps.md", "L")
    );

    // Check before REVIEWED -> incomplete exit 2 parity
    let (rc_b, rco_b) = run_b3(&[
        "guard",
        "review-ledger",
        "--repo-root",
        root_str,
        "--action",
        "check",
        "--ledger-path",
        ".b3/ship/l-rust.md",
    ]);
    let (pc_b, pco_b) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "review-ledger",
            "-RepoRoot",
            root_str,
            "-Action",
            "check",
            "-LedgerPath",
            ".b3/ship/l-ps.md",
        ],
    );
    assert_eq!(rc_b, 2);
    assert_eq!(pc_b, 2);
    assert_eq!(rco_b, pco_b);

    // Update U01 -> REVIEWED and cross-verify
    let (ru_r, ruo_r) = run_b3(&[
        "guard",
        "review-ledger",
        "--repo-root",
        root_str,
        "--action",
        "update",
        "--ledger-path",
        ".b3/ship/l-rust.md",
        "--unit-id",
        "U01",
        "--status",
        "REVIEWED",
        "--findings",
        "none",
        "--review-independence",
        "INDEPENDENT",
    ]);
    let (ru_p, ruo_p) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "review-ledger",
            "-RepoRoot",
            root_str,
            "-Action",
            "update",
            "-LedgerPath",
            ".b3/ship/l-ps.md",
            "-UnitId",
            "U01",
            "-Status",
            "REVIEWED",
            "-Findings",
            "none",
            "-ReviewIndependence",
            "INDEPENDENT",
        ],
    );
    assert_eq!(ru_r, 0);
    assert_eq!(ru_p, 0);
    assert_eq!(
        ruo_r.replace("l-rust.md", "L"),
        ruo_p.replace("l-ps.md", "L")
    );
    let l_rust_txt = fs::read_to_string(root.join(".b3/ship/l-rust.md")).unwrap();
    let l_ps_txt = fs::read_to_string(root.join(".b3/ship/l-ps.md")).unwrap();
    assert_eq!(l_rust_txt, l_ps_txt);

    // Check PASS (cross check PS ledger with Rust and Rust ledger with PS)
    let (rc_p, rco_p) = run_b3(&[
        "guard",
        "review-ledger",
        "--repo-root",
        root_str,
        "--action",
        "check",
        "--ledger-path",
        ".b3/ship/l-ps.md",
    ]);
    let (pc_r, pco_r) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "review-ledger",
            "-RepoRoot",
            root_str,
            "-Action",
            "check",
            "-LedgerPath",
            ".b3/ship/l-rust.md",
        ],
    );
    assert_eq!(rc_p, 0);
    assert_eq!(pc_r, 0);
    assert_eq!(rco_p, pco_r);

    // Legacy file normalize parity (LARGE -> L and insert review_independence=UNKNOWN)
    let legacy_sample = "schema=b3-review-ledger-v1\nsize_class=LARGE\nbudget_status=OK\n";
    fs::write(root.join(".b3/ship/leg-r.md"), legacy_sample).unwrap();
    fs::write(root.join(".b3/ship/leg-p.md"), legacy_sample).unwrap();
    let (rnf, rnfo) = run_b3(&[
        "guard",
        "review-ledger",
        "--repo-root",
        root_str,
        "--action",
        "normalize",
        "--ledger-path",
        ".b3/ship/leg-r.md",
    ]);
    let (pnf, pnfo) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "review-ledger",
            "-RepoRoot",
            root_str,
            "-Action",
            "normalize",
            "-LedgerPath",
            ".b3/ship/leg-p.md",
        ],
    );
    assert_eq!(rnf, 0);
    assert_eq!(pnf, 0);
    assert_eq!(rnfo.replace("leg-r.md", "L"), pnfo.replace("leg-p.md", "L"));
    assert_eq!(
        fs::read_to_string(root.join(".b3/ship/leg-r.md")).unwrap(),
        fs::read_to_string(root.join(".b3/ship/leg-p.md")).unwrap()
    );
}

#[test]
fn wrapper_forwarding_context_cache_matches_powershell() {
    let tmp = TempDirGuard::new("ctx-cache");
    let root = &tmp.path;
    let head_sha = init_git_repo(root);
    let root_str = root.to_str().unwrap();

    fs::create_dir_all(root.join(".b3/ship")).unwrap();
    fs::write(root.join(".b3/ship/summary.md"), "summary v1\n").unwrap();

    let (rr, rro) = run_b3(&[
        "guard",
        "context-cache",
        "--repo-root",
        root_str,
        "--action",
        "record",
        "--cache-path",
        ".b3/ship/ctx-r.md",
        "--scope-id",
        "wave/u01",
        "--anchor-paths",
        "src/app.txt",
        "--graph-index-sha",
        &head_sha,
        "--summary-ref",
        ".b3/ship/summary.md",
    ]);
    let (pr, pro) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "context-cache",
            "-RepoRoot",
            root_str,
            "-Action",
            "record",
            "-CachePath",
            ".b3/ship/ctx-p.md",
            "-ScopeId",
            "wave/u01",
            "-AnchorPaths",
            "src/app.txt",
            "-GraphIndexSha",
            &head_sha,
            "-SummaryRef",
            ".b3/ship/summary.md",
        ],
    );
    assert_eq!(rr, 0);
    assert_eq!(pr, 0);
    assert_eq!(rro.replace("ctx-r.md", "C"), pro.replace("ctx-p.md", "C"));

    // Cross check fresh
    let (rc1, rco1) = run_b3(&[
        "guard",
        "context-cache",
        "--repo-root",
        root_str,
        "--action",
        "check",
        "--cache-path",
        ".b3/ship/ctx-p.md",
        "--scope-id",
        "wave/u01",
        "--anchor-paths",
        "src/app.txt",
        "--scope-paths",
        "src/app.txt",
        "--graph-index-sha",
        &head_sha,
        "--summary-ref",
        ".b3/ship/summary.md",
    ]);
    let (pc1, pco1) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "context-cache",
            "-RepoRoot",
            root_str,
            "-Action",
            "check",
            "-CachePath",
            ".b3/ship/ctx-r.md",
            "-ScopeId",
            "wave/u01",
            "-AnchorPaths",
            "src/app.txt",
            "-ScopePaths",
            "src/app.txt",
            "-GraphIndexSha",
            &head_sha,
            "-SummaryRef",
            ".b3/ship/summary.md",
        ],
    );
    assert_eq!(rc1, 0);
    assert_eq!(pc1, 0);
    assert_eq!(rco1, pco1);

    // Modify anchored file -> CONTEXT_STALE (exit 2 parity)
    fs::write(root.join("src/app.txt"), "v2\n").unwrap();
    let (rs, rso) = run_b3(&[
        "guard",
        "context-cache",
        "--repo-root",
        root_str,
        "--action",
        "check",
        "--cache-path",
        ".b3/ship/ctx-r.md",
        "--scope-paths",
        "src/app.txt",
    ]);
    let (ps_c, pso) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "context-cache",
            "-RepoRoot",
            root_str,
            "-Action",
            "check",
            "-CachePath",
            ".b3/ship/ctx-r.md",
            "-ScopePaths",
            "src/app.txt",
        ],
    );
    assert_eq!(rs, 2);
    assert_eq!(ps_c, 2);
    assert_eq!(rso, pso);

    // Corrupt CRLF cache -> CONTEXT_CORRUPT (exit 1 parity)
    let orig = fs::read_to_string(root.join(".b3/ship/ctx-r.md")).unwrap();
    fs::write(
        root.join(".b3/ship/ctx-crlf.md"),
        orig.replace('\n', "\r\n"),
    )
    .unwrap();
    let (rcf, rcfo) = run_b3(&[
        "guard",
        "context-cache",
        "--repo-root",
        root_str,
        "--action",
        "check",
        "--cache-path",
        ".b3/ship/ctx-crlf.md",
    ]);
    let (pcf, pcfo) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "context-cache",
            "-RepoRoot",
            root_str,
            "-Action",
            "check",
            "-CachePath",
            ".b3/ship/ctx-crlf.md",
        ],
    );
    assert_eq!(rcf, 1);
    assert_eq!(pcf, 1);
    assert_eq!(rcfo, pcfo);
}

#[test]
fn wrapper_forwarding_evidence_check_matches_powershell() {
    let tmp = TempDirGuard::new("evidence");
    let root = &tmp.path;
    let _head = init_git_repo(root);
    let root_str = root.to_str().unwrap();

    // Missing manifest -> exit 1 parity
    let (rm, rom) = run_b3(&[
        "guard",
        "evidence-check",
        "--repo-root",
        root_str,
        "--manifest-path",
        ".b3/research-ship/ev.txt",
    ]);
    let (pm, pom) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "evidence-check",
            "-RepoRoot",
            root_str,
            "-ManifestPath",
            ".b3/research-ship/ev.txt",
        ],
    );
    assert_eq!(rm, 1);
    assert_eq!(pm, 1);
    assert_eq!(rom, pom);

    // Write manifest via Rust and via PS, verify both fresh across both implementations
    let (rw, rwo) = run_b3(&[
        "guard",
        "evidence-check",
        "--repo-root",
        root_str,
        "--manifest-path",
        ".b3/research-ship/ev-r.txt",
        "--source-paths",
        "docs/guide.md,src/app.txt",
        "--write-manifest",
    ]);
    let (pw, pwo) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "evidence-check",
            "-RepoRoot",
            root_str,
            "-ManifestPath",
            ".b3/research-ship/ev-p.txt",
            "-SourcePaths",
            "docs/guide.md,src/app.txt",
            "-WriteManifest",
        ],
    );
    assert_eq!(rw, 0);
    assert_eq!(pw, 0);
    assert_eq!(rwo.replace("ev-r.txt", "E"), pwo.replace("ev-p.txt", "E"));

    let (rf, rfo) = run_b3(&[
        "guard",
        "evidence-check",
        "--repo-root",
        root_str,
        "--manifest-path",
        ".b3/research-ship/ev-p.txt",
        "--source-paths",
        "src/app.txt",
    ]);
    let (pf, pfo) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "evidence-check",
            "-RepoRoot",
            root_str,
            "-ManifestPath",
            ".b3/research-ship/ev-r.txt",
            "-SourcePaths",
            "src/app.txt",
        ],
    );
    assert_eq!(rf, 0);
    assert_eq!(pf, 0);
    assert_eq!(rfo, pfo);

    // Stale after file modification -> exit 2 parity
    fs::write(root.join("src/app.txt"), "modified\n").unwrap();
    let (rs, rso) = run_b3(&[
        "guard",
        "evidence-check",
        "--repo-root",
        root_str,
        "--manifest-path",
        ".b3/research-ship/ev-r.txt",
    ]);
    let (ps_c, pso) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "evidence-check",
            "-RepoRoot",
            root_str,
            "-ManifestPath",
            ".b3/research-ship/ev-r.txt",
        ],
    );
    assert_eq!(rs, 2);
    assert_eq!(ps_c, 2);
    assert_eq!(rso, pso);
}

#[test]
fn wrapper_forwarding_merge_policy_check_matches_powershell() {
    let tmp = TempDirGuard::new("merge-pol");
    let root = &tmp.path;
    let _init_sha = init_git_repo(root);
    let root_str = root.to_str().unwrap();

    // Ensure canonical branch is named main
    git_in(root, &["branch", "-M", "main"]);
    fs::create_dir_all(root.join(".b3")).unwrap();
    fs::write(
        root.join(".b3/research-policy.json"),
        "{\"auto_merge\":\"authorized\",\"require_ci\":true,\"require_review\":true}\n",
    )
    .unwrap();
    git_in(root, &["add", ".b3/research-policy.json"]);
    git_in(root, &["commit", "-q", "-m", "add policy on main"]);
    let main_sha = git_in(root, &["rev-parse", "HEAD"]);

    // Feature branch commit
    git_in(root, &["checkout", "-q", "-b", "feat/work"]);
    fs::write(root.join("src/app.txt"), "v2 feature\n").unwrap();
    git_in(root, &["add", "src/app.txt"]);
    git_in(root, &["commit", "-q", "-m", "feat work"]);
    let feat_sha = git_in(root, &["rev-parse", "HEAD"]);

    // R001: caller CiStatus=PASS without local receipt or ledger cannot authorize disabled policy
    fs::write(
        root.join(".b3/dis-policy.json"),
        "{\"auto_merge\":\"disabled\",\"require_ci\":true,\"require_review\":false}\n",
    )
    .unwrap();
    git_in(root, &["add", ".b3/dis-policy.json"]);
    git_in(root, &["commit", "-q", "-m", "add dis policy"]);
    let dis_head = git_in(root, &["rev-parse", "HEAD"]);
    // Wait: test local_only / disabled requires default path if branch differs; switch temporarily to test disabled on clean tree vs trunk
    git_in(root, &["reset", "--hard", "-q", &feat_sha]);

    // Missing ledger blocks authorized merge -> exit 1 parity
    let (rb, rbo) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        root_str,
        "--target-branch",
        "main",
    ]);
    let (pb, pbo) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "merge-policy-check",
            "-RepoRoot",
            root_str,
            "-TargetBranch",
            "main",
        ],
    );
    assert_eq!(rb, 1);
    assert_eq!(pb, 1);
    assert_eq!(rbo, pbo);

    // Build valid ledger + verify receipt -> MERGE_AUTHORIZED exit 0 parity
    let (vr_c, _) = run_b3(&[
        "guard",
        "verify-run",
        "--repo-root",
        root_str,
        "--verify-cmd",
        "exit 0",
        "--receipt-path",
        ".b3/ship/v.txt",
        "--relevant-paths",
        "src/app.txt",
    ]);
    assert_eq!(vr_c, 0);
    let (li_c, _) = run_b3(&[
        "guard",
        "review-ledger",
        "--repo-root",
        root_str,
        "--action",
        "init",
        "--ledger-path",
        ".b3/ship/l.md",
        "--base-sha",
        &main_sha,
        "--target-ref",
        &dis_head[..0],
    ]);
    assert_eq!(li_c, 0);
    let (lu_c, _) = run_b3(&[
        "guard",
        "review-ledger",
        "--repo-root",
        root_str,
        "--action",
        "update",
        "--ledger-path",
        ".b3/ship/l.md",
        "--unit-id",
        "U01",
        "--status",
        "REVIEWED",
        "--findings",
        "none",
        "--receipt-path",
        ".b3/ship/v.txt",
        "--review-independence",
        "INDEPENDENT",
    ]);
    assert_eq!(lu_c, 0);

    // Test R001 with caller CiStatus=PASS on a local disabled policy repo
    {
        let tmp_dis = TempDirGuard::new("merge-pol-dis");
        let dr = &tmp_dis.path;
        let _d_init = init_git_repo(dr);
        let dr_str = dr.to_str().unwrap();
        fs::create_dir_all(dr.join(".b3")).unwrap();
        fs::write(
            dr.join(".b3/research-policy.json"),
            "{\"auto_merge\":\"disabled\",\"require_ci\":true,\"require_review\":false}\n",
        )
        .unwrap();
        let (rd, rdo) = run_b3(&[
            "guard",
            "merge-policy-check",
            "--repo-root",
            dr_str,
            "--ci-status",
            "PASS",
        ]);
        let (pd, pdo) = run_ps_script(
            "scripts/b3-guard.ps1",
            &[
                "merge-policy-check",
                "-RepoRoot",
                dr_str,
                "-CiStatus",
                "PASS",
            ],
        );
        assert_eq!(rd, 1);
        assert_eq!(pd, 1);
        assert_eq!(
            rdo,
            "MERGE_BLOCKED: ci_evidence_unverified(caller_reported_ci_cannot_authorize)"
        );
        assert_eq!(rdo, pdo);
    }

    let (ra, rao) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        root_str,
        "--target-branch",
        "main",
        "--ledger-path",
        ".b3/ship/l.md",
    ]);
    let (pa, pao) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "merge-policy-check",
            "-RepoRoot",
            root_str,
            "-TargetBranch",
            "main",
            "-LedgerPath",
            ".b3/ship/l.md",
        ],
    );
    assert_eq!(ra, 0);
    assert_eq!(pa, 0);
    assert_eq!(rao, pao);

    // Post-merge fast-forward verification -> POST_MERGE_VERIFIED exit 0 parity
    git_in(root, &["checkout", "-q", "main"]);
    git_in(root, &["merge", "--ff-only", "-q", "feat/work"]);
    let (rp, rpo) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        root_str,
        "--post-merge",
        "--main-ref",
        "refs/heads/main",
        "--merged-sha",
        &feat_sha,
        "--head-sha",
        &feat_sha,
    ]);
    let (pp, ppo) = run_ps_script(
        "scripts/b3-guard.ps1",
        &[
            "merge-policy-check",
            "-RepoRoot",
            root_str,
            "-PostMerge",
            "-MainRef",
            "refs/heads/main",
            "-MergedSha",
            &feat_sha,
            "-HeadSha",
            &feat_sha,
        ],
    );
    assert_eq!(rp, 0);
    assert_eq!(pp, 0);
    assert_eq!(rpo, ppo);
}

#[test]
fn wrapper_forwarding_pr_verify_matches_node() {
    let tmp = TempDirGuard::new("pr-verify");
    let root = &tmp.path;
    let _init_sha = init_git_repo(root);
    let root_str = root.to_str().unwrap();

    // Non-GitHub origin remote -> origin_remote_not_github parity
    git_in(
        root,
        &[
            "remote",
            "add",
            "origin",
            "https://gitlab.com/acme/demo.git",
        ],
    );
    let (rn, rno) = run_b3(&[
        "pr",
        "verify",
        "--mode",
        "pre-merge",
        "--repo-root",
        root_str,
        "--pr-number",
        "42",
    ]);
    let (pn, pno) = run_ps_script(
        "scripts/b3-github-verify.ps1",
        &[
            "-Mode",
            "pre-merge",
            "-RepoRoot",
            root_str,
            "-PrNumber",
            "42",
        ],
    );
    assert_eq!(rn, 1);
    assert_eq!(pn, 1);
    assert_eq!(rno, pno);

    // Switch to GitHub origin + set up mock gh.cmd
    git_in(
        root,
        &[
            "remote",
            "set-url",
            "origin",
            "https://github.com/acme/demo.git",
        ],
    );
    let base_sha = "1111111111111111111111111111111111111111";
    let head_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    let merge_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    let mock_dir = root.join(".b3/mock");
    fs::create_dir_all(&mock_dir).unwrap();
    fs::write(
        mock_dir.join("pull_open.json"),
        format!(
            "{{\"number\":42,\"state\":\"open\",\"merged\":false,\"draft\":false,\"mergeable\":true,\"mergeable_state\":\"clean\",\"base\":{{\"ref\":\"main\",\"sha\":\"{base_sha}\",\"repo\":{{\"full_name\":\"acme/demo\",\"default_branch\":\"main\"}}}},\"head\":{{\"ref\":\"feat/x\",\"sha\":\"{head_sha}\",\"repo\":{{\"full_name\":\"acme/demo\"}}}}}}"
        ),
    )
    .unwrap();
    fs::write(
        mock_dir.join("pull_merged.json"),
        format!(
            "{{\"number\":42,\"state\":\"closed\",\"merged\":true,\"merged_at\":\"2026-11-26T10:00:00Z\",\"merge_commit_sha\":\"{merge_sha}\",\"commits\":2,\"base\":{{\"ref\":\"main\",\"sha\":\"{base_sha}\",\"repo\":{{\"full_name\":\"acme/demo\",\"default_branch\":\"main\"}}}},\"head\":{{\"ref\":\"feat/x\",\"sha\":\"{head_sha}\",\"repo\":{{\"full_name\":\"acme/demo\"}}}}}}"
        ),
    )
    .unwrap();
    fs::write(
        mock_dir.join("branch.json"),
        format!("{{\"name\":\"main\",\"commit\":{{\"sha\":\"{base_sha}\"}}}}"),
    )
    .unwrap();
    fs::write(
        mock_dir.join("files.json"),
        "[{\"filename\":\"src/b.ts\",\"previous_filename\":\"src/a.ts\"},{\"filename\":\"README.md\"}]",
    )
    .unwrap();
    fs::write(
        mock_dir.join("checks.json"),
        format!(
            "[{{\"check_runs\":[{{\"id\":10,\"name\":\"ci\",\"status\":\"completed\",\"conclusion\":\"success\",\"head_sha\":\"{head_sha}\",\"app\":{{\"id\":1}}}}]}}]"
        ),
    )
    .unwrap();
    fs::write(
        mock_dir.join("status.json"),
        format!(
            "[{{\"sha\":\"{head_sha}\",\"total_count\":1,\"state\":\"success\",\"statuses\":[{{\"context\":\"lint\",\"state\":\"success\"}}]}}]"
        ),
    )
    .unwrap();
    fs::write(
        mock_dir.join("compare.json"),
        "{\"status\":\"identical\",\"behind_by\":0}",
    )
    .unwrap();

    let gh_cmd = mock_dir.join("gh.cmd");
    let gh_bat = "@echo off\r\nif \"%B3_MOCK_MODE%\"==\"auth401\" (\r\n  echo HTTP 401 Unauthorized 1>&2\r\n  exit /b 1\r\n)\r\nset \"EP=%~2\"\r\nif \"%~2\"==\"--paginate\" set \"EP=%~4\"\r\nif \"%EP%\"==\"repos/acme/demo/pulls/42\" (\r\n  if \"%B3_MOCK_MODE%\"==\"notfound\" (\r\n    echo HTTP 404 Not Found 1>&2\r\n    exit /b 1\r\n  )\r\n  if \"%B3_MOCK_MODE%\"==\"merged\" (\r\n    type \"%~dp0pull_merged.json\"\r\n  ) else (\r\n    type \"%~dp0pull_open.json\"\r\n  )\r\n  exit /b 0\r\n)\r\nif \"%EP%\"==\"repos/acme/demo/branches/main\" (\r\n  type \"%~dp0branch.json\"\r\n  exit /b 0\r\n)\r\nif \"%EP%\"==\"repos/acme/demo/pulls/42/files?per_page=100\" (\r\n  type \"%~dp0files.json\"\r\n  exit /b 0\r\n)\r\nif \"%EP%\"==\"repos/acme/demo/commits/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/check-runs?per_page=100\" (\r\n  type \"%~dp0checks.json\"\r\n  exit /b 0\r\n)\r\nif \"%EP%\"==\"repos/acme/demo/commits/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/status?per_page=100\" (\r\n  type \"%~dp0status.json\"\r\n  exit /b 0\r\n)\r\nif \"%EP%\"==\"repos/acme/demo/compare/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb...1111111111111111111111111111111111111111\" (\r\n  type \"%~dp0compare.json\"\r\n  exit /b 0\r\n)\r\necho Unexpected endpoint: %EP% 1>&2\r\nexit /b 1\r\n";
    fs::write(&gh_cmd, gh_bat).unwrap();
    let gh_cmd_str = gh_cmd.to_str().unwrap();

    let run_both = |mode_val: &str, mock_env: &str| -> ((i32, String), (i32, String)) {
        let r_out = Command::new(b3_bin())
            .env("B3_GH_BIN", gh_cmd_str)
            .env("B3_MOCK_MODE", mock_env)
            .args([
                "pr",
                "verify",
                "--mode",
                mode_val,
                "--repo-root",
                root_str,
                "--pr-number",
                "42",
            ])
            .output()
            .expect("run b3 pr verify");
        let r_res = (
            r_out.status.code().unwrap_or(-1),
            String::from_utf8_lossy(&r_out.stdout)
                .trim_end_matches(&['\r', '\n'][..])
                .replace("\r\n", "\n"),
        );

        let ps_path = repo_root().join("scripts/b3-github-verify.ps1");
        let p_out = Command::new("powershell")
            .env("B3_BIN", b3_bin())
            .env("B3_GH_BIN", gh_cmd_str)
            .env("B3_MOCK_MODE", mock_env)
            .arg("-NoProfile")
            .arg("-ExecutionPolicy")
            .arg("Bypass")
            .arg("-File")
            .arg(&ps_path)
            .args(["-Mode", mode_val, "-RepoRoot", root_str, "-PrNumber", "42"])
            .output()
            .expect("run thin ps verify wrapper");
        let p_res = (
            p_out.status.code().unwrap_or(-1),
            String::from_utf8_lossy(&p_out.stdout)
                .trim_end_matches(&['\r', '\n'][..])
                .replace("\r\n", "\n"),
        );
        (r_res, p_res)
    };

    // 1. pre-merge open PR -> exact exit 0 + schema=b3-gh-verify-v2 output parity
    let ((r1c, r1o), (p1c, p1o)) = run_both("pre-merge", "open");
    assert_eq!(r1c, 0);
    assert_eq!(p1c, 0);
    assert_eq!(r1o, p1o);

    // 2. post-merge merged PR -> exact exit 0 parity
    let ((r2c, r2o), (p2c, p2o)) = run_both("post-merge", "merged");
    assert_eq!(r2c, 0);
    assert_eq!(p2c, 0);
    assert_eq!(r2o, p2o);

    // 3. 404 pr_not_found -> exit 1 parity
    let ((r3c, r3o), (p3c, p3o)) = run_both("pre-merge", "notfound");
    assert_eq!(r3c, 1);
    assert_eq!(p3c, 1);
    assert_eq!(r3o, p3o);

    // 4. 401 github_auth_failed -> exit 2 parity
    let ((r4c, r4o), (p4c, p4o)) = run_both("pre-merge", "auth401");
    assert_eq!(r4c, 2);
    assert_eq!(p4c, 2);
    assert_eq!(r4o, p4o);
}

#[test]
fn wrapper_forwarding_pr_github_matches_node() {
    let tmp = TempDirGuard::new("pr-github-diff");
    let root = tmp.path.join("repo");
    fs::create_dir_all(&root).unwrap();
    let _head_sha = init_git_repo(&root);
    let root_str = root.to_str().unwrap();

    // Commit a fix file for resolve verification
    fs::write(root.join("src/app.txt"), "line1\nfixed\n").unwrap();
    git_in(&root, &["add", "src/app.txt"]);
    git_in(&root, &["commit", "-q", "-m", "fix app"]);
    let fix_sha = git_in(&root, &["rev-parse", "HEAD"]);
    let (vr_c, _) = run_b3(&[
        "guard",
        "verify-run",
        "--repo-root",
        root_str,
        "--task-id",
        "T001",
        "--receipt-path",
        ".b3/ship/verify/pr.receipt",
        "--verify-cmd",
        "node -v",
        "--relevant-paths",
        "src/app.txt",
    ]);
    assert_eq!(vr_c, 0);

    let fixtures = tmp.path.join("fixtures");
    fs::create_dir_all(&fixtures).unwrap();
    let reply_body = fixtures.join("reply.md");
    fs::write(&reply_body, "Verified fix cleanly.\n").unwrap();
    let summary_body = fixtures.join("summary.md");
    fs::write(&summary_body, "## PR Review\n\nAll checked.\n").unwrap();
    let inline_json = fixtures.join("inline.json");
    fs::write(
        &inline_json,
        "[{\"status\":\"CONFIRMED\",\"severity\":\"MEDIUM\",\"path\":\"src/app.txt\",\"line\":2,\"side\":\"RIGHT\",\"title\":\"Check line\",\"body\":\"Verify line 2\",\"suggested_fix\":\"Keep fixed\"}]",
    )
    .unwrap();
    let ev_json = fixtures.join("evidence.json");
    fs::write(
        &ev_json,
        format!(
            "{{\"schema\":\"b3-pr-verify-evidence-v1\",\"repo\":\"acme/demo\",\"pr\":7,\"head_sha\":\"{fix_sha}\",\"thread_id\":\"PRRT_1\",\"fix_commit\":\"{fix_sha}\",\"resolution_basis\":\"CONFIRMED_FIXED\",\"target_path\":\"src/app.txt\",\"fixed_paths\":[\"src/app.txt\"],\"checked_command\":\"node -v\",\"verify_receipt_path\":\".b3/ship/verify/pr.receipt\",\"summary\":\"Fixed line 2 cleanly.\"}}"
        ),
    )
    .unwrap();

    // Stateful Node mock gh CLI shared per test run
    let mock_js = fixtures.join("mock-gh.mjs");
    fs::write(
        &mock_js,
        r#"import fs from 'node:fs';
const stateFile = process.env.MOCK_STATE_FILE;
const state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
const args = process.argv.slice(2);
const ep = args[1] || '';
let input = '';
try { input = fs.readFileSync(0, 'utf8'); } catch {}
const out = (o) => { process.stdout.write(JSON.stringify(o)); process.exit(0); };
if (ep === 'graphql') {
  const req = JSON.parse(input || '{}');
  const q = req.query || '';
  const v = req.variables || {};
  if (q.includes('addPullRequestReviewThreadReply')) {
    const cid = 'PRRC_' + (state.seq++);
    state.thread.comments.push({ id: cid, author: { login: 'octocat' }, body: v.body });
    fs.writeFileSync(stateFile, JSON.stringify(state));
    out({ data: { addPullRequestReviewThreadReply: { comment: { id: cid, url: 'https://example.test/' + cid } } } });
  }
  if (q.includes('resolveReviewThread')) {
    state.thread.isResolved = true;
    fs.writeFileSync(stateFile, JSON.stringify(state));
    out({ data: { resolveReviewThread: { thread: { id: state.thread.id, isResolved: true } } } });
  }
  if (q.includes('comment: node(id: $commentId)')) {
    const c = state.thread.comments.find((x) => x.id === v.commentId) || null;
    out({ data: { repository: { pullRequest: { state: 'OPEN', headRefOid: state.head } }, thread: { id: state.thread.id, isResolved: state.thread.isResolved, pullRequest: { number: 7, repository: { nameWithOwner: 'acme/demo' } } }, comment: c ? { id: c.id, author: c.author, body: c.body, pullRequest: { number: 7 } } : null } });
  }
  if (q.includes('node(id: $threadId)') && q.includes('headRefOid')) {
    out({ data: { repository: { pullRequest: { state: 'OPEN', headRefOid: state.head } }, node: { id: state.thread.id, isResolved: state.thread.isResolved, pullRequest: { number: 7, repository: { nameWithOwner: 'acme/demo' } } } } });
  }
  if (q.includes('node(id: $threadId)')) {
    out({ data: { node: { id: state.thread.id, isResolved: state.thread.isResolved, isOutdated: false, path: state.thread.path, line: 2, originalLine: 2, pullRequest: { number: 7, repository: { nameWithOwner: 'acme/demo' } }, comments: { totalCount: state.thread.comments.length, pageInfo: { hasNextPage: false, endCursor: null }, nodes: state.thread.comments } } } });
  }
  if (q.includes('reviewThreads(')) {
    out({ data: { viewer: { login: 'octocat' }, repository: { pullRequest: { number: 7, state: 'OPEN', headRefOid: state.head, title: 'T<!-- untrusted -->', baseRefName: 'main', headRefName: 'feat/x', reviewThreads: { pageInfo: { hasNextPage: false, endCursor: null }, nodes: [{ id: state.thread.id, isResolved: state.thread.isResolved, isOutdated: false, path: state.thread.path, line: 2, originalLine: 2, comments: { totalCount: state.thread.comments.length, pageInfo: { hasNextPage: false, endCursor: null }, nodes: state.thread.comments } }] } } } } });
  }
  out({ data: { viewer: { login: 'octocat' }, repository: { pullRequest: { number: 7, state: 'OPEN', headRefOid: state.head } } } });
}
if (ep.startsWith('repos/acme/demo/issues/7/comments?')) out([]);
if (ep === 'repos/acme/demo/issues/7/comments' && args.includes('POST')) {
  const b = JSON.parse(input || '{}');
  const id = String(state.seq++);
  state.issueComments.push({ id, user: { login: 'octocat' }, body: b.body, issue_url: 'https://api.github.com/repos/acme/demo/issues/7' });
  fs.writeFileSync(stateFile, JSON.stringify(state));
  out({ id });
}
if (ep.startsWith('repos/acme/demo/pulls/7/reviews?')) out(state.reviews);
if (ep === 'repos/acme/demo/pulls/7/reviews' && args.includes('POST')) {
  const b = JSON.parse(input || '{}');
  const id = String(state.seq++);
  state.reviews.push({ id, user: { login: 'octocat' }, state: 'COMMENTED', commit_id: b.commit_id, body: b.body, comments: b.comments || [] });
  fs.writeFileSync(stateFile, JSON.stringify(state));
  out({ id });
}
if (ep.startsWith('repos/acme/demo/pulls/7/reviews/') && ep.endsWith('/comments?per_page=100&page=1')) {
  const parts = ep.split('/');
  const rid = parts[6];
  const rev = state.reviews.find((r) => String(r.id) === rid);
  out(rev ? rev.comments : []);
}
if (ep.startsWith('repos/acme/demo/pulls/7/reviews/')) {
  const rid = ep.split('/').pop();
  const rev = state.reviews.find((r) => String(r.id) === rid) || null;
  out(rev);
}
if (ep.startsWith('repos/acme/demo/pulls/7/files?')) out([{ filename: 'src/app.txt', patch: '@@ -1 +1,2 @@\n line1\n+fixed\n' }]);
if (ep.startsWith('repos/acme/demo/compare/')) out({ status: 'identical', behind_by: 0 });
if (ep.startsWith('repos/acme/demo/commits/')) out({ files: [{ filename: 'src/app.txt' }] });
process.stderr.write('Unexpected ep: ' + ep);
process.exit(1);
"#,
    )
    .unwrap();

    let gh_cmd = fixtures.join("gh.cmd");
    fs::write(&gh_cmd, "@echo off\r\nnode \"%~dp0mock-gh.mjs\" %*\r\n").unwrap();
    let gh_cmd_str = gh_cmd.to_str().unwrap();

    let init_state = format!(
        "{{\"head\":\"{fix_sha}\",\"seq\":100,\"thread\":{{\"id\":\"PRRT_1\",\"isResolved\":false,\"path\":\"src/app.txt\",\"comments\":[]}},\"issueComments\":[],\"reviews\":[]}}"
    );
    let ps_adapter = repo_root().join("scripts/b3-pr-github.ps1");

    let run_pair = |case_tag: &str, args: &[&str]| -> ((i32, String), (i32, String)) {
        let st_r = fixtures.join(format!("st-r-{case_tag}.json"));
        let st_n = fixtures.join(format!("st-n-{case_tag}.json"));
        fs::write(&st_r, &init_state).unwrap();
        fs::write(&st_n, &init_state).unwrap();

        let state_dir = root.join(".git/b3/pr-feedback");
        if state_dir.exists() {
            fs::remove_dir_all(&state_dir).unwrap();
        }
        let mut r_args = vec!["pr"];
        r_args.extend_from_slice(args);
        let r_out = Command::new(b3_bin())
            .env("B3_GH_BIN", gh_cmd_str)
            .env("MOCK_STATE_FILE", &st_r)
            .args(&r_args)
            .output()
            .expect("run b3 pr");
        let r_res = (
            r_out.status.code().unwrap_or(-1),
            String::from_utf8_lossy(&r_out.stdout)
                .trim_end_matches(&['\r', '\n'][..])
                .to_string(),
        );

        if state_dir.exists() {
            fs::remove_dir_all(&state_dir).unwrap();
        }
        let n_out = Command::new("powershell")
            .env("B3_BIN", b3_bin())
            .env("B3_GH_BIN", gh_cmd_str)
            .env("MOCK_STATE_FILE", &st_n)
            .arg("-NoProfile")
            .arg("-ExecutionPolicy")
            .arg("Bypass")
            .arg("-File")
            .arg(&ps_adapter)
            .args(args)
            .output()
            .expect("run ps b3-pr-github.ps1 wrapper");
        let n_res = (
            n_out.status.code().unwrap_or(-1),
            String::from_utf8_lossy(&n_out.stdout)
                .trim_end_matches(&['\r', '\n'][..])
                .to_string(),
        );
        (r_res, n_res)
    };

    // 1. Draft reply parity
    let ((r1c, r1o), (n1c, n1o)) = run_pair(
        "reply-draft",
        &[
            "reply",
            "--repo",
            "acme/demo",
            "--pr",
            "7",
            "--expected-head",
            &fix_sha,
            "--target-kind",
            "review_thread",
            "--target-id",
            "PRRT_1",
            "--body-file",
            reply_body.to_str().unwrap(),
            "--draft",
        ],
    );
    assert_eq!(r1c, 0);
    assert_eq!(n1c, 0);
    assert_eq!(r1o, n1o);

    // 2. Draft comment --mode both parity
    let ((r2c, r2o), (n2c, n2o)) = run_pair(
        "comment-draft",
        &[
            "comment",
            "--repo",
            "acme/demo",
            "--pr",
            "7",
            "--expected-head",
            &fix_sha,
            "--mode",
            "both",
            "--summary-file",
            summary_body.to_str().unwrap(),
            "--inline-json",
            inline_json.to_str().unwrap(),
            "--draft",
        ],
    );
    assert_eq!(r2c, 0);
    assert_eq!(n2c, 0);
    assert_eq!(r2o, n2o);

    // 3. Fetch metadata_first parity
    let ((r3c, r3o), (n3c, n3o)) =
        run_pair("fetch", &["fetch", "--repo", "acme/demo", "--pr", "7"]);
    assert_eq!(r3c, 0);
    assert_eq!(n3c, 0);
    assert_eq!(r3o, n3o);

    // 4. Reply --authorize-write parity + comment --authorize-write parity
    let ((r4c, r4o), (n4c, n4o)) = run_pair(
        "reply-auth",
        &[
            "reply",
            "--repo",
            "acme/demo",
            "--pr",
            "7",
            "--repo-root",
            root_str,
            "--expected-head",
            &fix_sha,
            "--target-kind",
            "review_thread",
            "--target-id",
            "PRRT_1",
            "--body-file",
            reply_body.to_str().unwrap(),
            "--authorize-write",
        ],
    );
    assert_eq!(r4c, 0);
    assert_eq!(n4c, 0);
    assert_eq!(r4o, n4o);

    let ((r5c, r5o), (n5c, n5o)) = run_pair(
        "comment-auth",
        &[
            "comment",
            "--repo",
            "acme/demo",
            "--pr",
            "7",
            "--repo-root",
            root_str,
            "--expected-head",
            &fix_sha,
            "--mode",
            "both",
            "--summary-file",
            summary_body.to_str().unwrap(),
            "--inline-json",
            inline_json.to_str().unwrap(),
            "--authorize-write",
        ],
    );
    assert_eq!(r5c, 0);
    assert_eq!(n5c, 0);
    assert_eq!(r5o, n5o);

    // 5. Resolve --authorize-resolve with real b3-verify receipt & clean tree
    let ((r6c, r6o), (n6c, n6o)) = run_pair(
        "resolve-auth",
        &[
            "resolve",
            "--repo",
            "acme/demo",
            "--pr",
            "7",
            "--repo-root",
            root_str,
            "--expected-head",
            &fix_sha,
            "--thread-id",
            "PRRT_1",
            "--fix-commit",
            &fix_sha,
            "--evidence-file",
            ev_json.to_str().unwrap(),
            "--authorize-resolve",
        ],
    );
    assert_eq!(r6c, 0);
    assert_eq!(n6c, 0);
    assert_eq!(r6o, n6o);

    // 6. Reconcile empty state parity
    let ((r7c, r7o), (n7c, n7o)) = run_pair(
        "reconcile",
        &[
            "reconcile",
            "--repo",
            "acme/demo",
            "--pr",
            "7",
            "--repo-root",
            root_str,
        ],
    );
    assert_eq!(r7c, 0);
    assert_eq!(n7c, 0);
    assert_eq!(r7o, n7o);
}

#[test]
fn wrapper_forwarding_sync_and_install_product_match_powershell() {
    let tmp = TempDirGuard::new("adapters-diff");
    let b3_home = repo_root();
    let b3_home_str = b3_home.to_str().unwrap();

    // Clone a minimal B3 checkout copy with real skills/, commands/, agents/, adapters/, config/
    let copy_dir = |src: &Path, dst: &Path| {
        fs::create_dir_all(dst).unwrap();
        let out = Command::new("powershell")
            .args([
                "-NoProfile",
                "-Command",
                &format!(
                    "Copy-Item -LiteralPath '{}' -Destination '{}' -Recurse -Force",
                    src.display(),
                    dst.parent().unwrap().display()
                ),
            ])
            .output()
            .expect("copy dir");
        assert!(out.status.success());
    };

    let fx_r = tmp.path.join("fx-rust");
    let fx_p = tmp.path.join("fx-ps");
    for fx in [&fx_r, &fx_p] {
        fs::create_dir_all(fx.join("adapters/command-skills")).unwrap();
        copy_dir(&b3_home.join("skills"), &fx.join("skills"));
        copy_dir(&b3_home.join("commands"), &fx.join("commands"));
        copy_dir(&b3_home.join("agents"), &fx.join("agents"));
        copy_dir(
            &b3_home.join("adapters/command-skills"),
            &fx.join("adapters/command-skills"),
        );
        fs::copy(
            b3_home.join("adapters/sync-skills.ps1"),
            fx.join("adapters/sync-skills.ps1"),
        )
        .unwrap();
        fs::create_dir_all(fx.join("config")).unwrap();
        fs::copy(
            b3_home.join("config/models.example.md"),
            fx.join("config/models.example.md"),
        )
        .unwrap();
    }

    let mod_r = tmp.path.join("models-r.md");
    let mod_p = tmp.path.join("models-p.md");

    // 1. b3 sync antigravity + verify-only vs PS legacy
    let r_ag = Command::new(b3_bin())
        .env("B3_MODELS_PERSONAL", &mod_r)
        .args([
            "sync",
            "--repo-root",
            fx_r.to_str().unwrap(),
            "--host",
            "antigravity",
        ])
        .output()
        .unwrap();
    assert_eq!(r_ag.status.code(), Some(0));
    let p_ag = Command::new("powershell")
        .env("B3_BIN", b3_bin())
        .env("B3_MODELS_PERSONAL", &mod_p)
        .arg("-NoProfile")
        .arg("-ExecutionPolicy")
        .arg("Bypass")
        .arg("-File")
        .arg(fx_p.join("adapters/sync-skills.ps1"))
        .args(["-HostName", "antigravity"])
        .output()
        .unwrap();
    assert_eq!(p_ag.status.code(), Some(0));
    let r_ag_norm = replace_path_both(
        replace_path_both(
            String::from_utf8_lossy(&r_ag.stdout).into_owned(),
            &fx_r,
            "FX",
        ),
        &mod_r,
        "MOD",
    )
    .replace("\r\n", "\n");
    let p_ag_norm = replace_path_both(
        replace_path_both(
            String::from_utf8_lossy(&p_ag.stdout).into_owned(),
            &fx_p,
            "FX",
        ),
        &mod_p,
        "MOD",
    )
    .replace("\r\n", "\n");
    assert_eq!(r_ag_norm, p_ag_norm);

    let r_ag_v = Command::new(b3_bin())
        .args([
            "sync",
            "--repo-root",
            fx_r.to_str().unwrap(),
            "--host",
            "antigravity",
            "--verify-only",
        ])
        .output()
        .unwrap();
    assert_eq!(r_ag_v.status.code(), Some(0));
    assert!(String::from_utf8_lossy(&r_ag_v.stdout).contains("verify ok:"));

    // 2. b3 sync codex (NTFS junction flattened index via Win32 DeviceIoControl) + verify-only
    let r_cx = Command::new(b3_bin())
        .env("B3_SKIP_MODEL_INIT", "1")
        .args([
            "sync",
            "--repo-root",
            fx_r.to_str().unwrap(),
            "--host",
            "codex",
        ])
        .output()
        .unwrap();
    assert_eq!(r_cx.status.code(), Some(0));
    let r_cx_v = Command::new(b3_bin())
        .args([
            "sync",
            "--repo-root",
            fx_r.to_str().unwrap(),
            "--host",
            "codex",
            "--verify-only",
        ])
        .output()
        .unwrap();
    assert_eq!(r_cx_v.status.code(), Some(0));
    assert!(String::from_utf8_lossy(&r_cx_v.stdout).contains("verify ok:"));
    // Confirm PowerShell wrapper sees the created junction identically via -VerifyOnly
    let p_cx_v = Command::new("powershell")
        .env("B3_BIN", b3_bin())
        .arg("-NoProfile")
        .arg("-ExecutionPolicy")
        .arg("Bypass")
        .arg("-File")
        .arg(fx_r.join("adapters/sync-skills.ps1"))
        .args(["-HostName", "codex", "-VerifyOnly"])
        .output()
        .unwrap();
    assert_eq!(p_cx_v.status.code(), Some(0));

    // 3. b3 install product codex parity vs legacy install-product.ps1
    let prod_r = tmp.path.join("prod-rust");
    let prod_p = tmp.path.join("prod-ps");
    fs::create_dir_all(&prod_r).unwrap();
    fs::create_dir_all(&prod_p).unwrap();

    let mod_pr = tmp.path.join("models-prod-r.md");
    let mod_pp = tmp.path.join("models-prod-p.md");
    let inst_ps = b3_home.join("adapters/install-product.ps1");

    let r_ip = Command::new(b3_bin())
        .env("B3_MODELS_PERSONAL", &mod_pr)
        .args([
            "install",
            "product",
            "--product-root",
            prod_r.to_str().unwrap(),
            "--b3-home",
            b3_home_str,
            "--host",
            "codex",
        ])
        .output()
        .unwrap();
    assert_eq!(r_ip.status.code(), Some(0));
    let p_ip = Command::new("powershell")
        .env("B3_BIN", b3_bin())
        .env("B3_MODELS_PERSONAL", &mod_pp)
        .arg("-NoProfile")
        .arg("-ExecutionPolicy")
        .arg("Bypass")
        .arg("-File")
        .arg(&inst_ps)
        .args([
            "-ProductRoot",
            prod_p.to_str().unwrap(),
            "-B3Home",
            b3_home_str,
            "-HostName",
            "codex",
        ])
        .output()
        .unwrap();
    assert_eq!(p_ip.status.code(), Some(0));
    let r_ip_norm = replace_path_both(
        replace_path_both(
            String::from_utf8_lossy(&r_ip.stdout).into_owned(),
            &prod_r,
            "PROD",
        ),
        &mod_pr,
        "MOD",
    )
    .replace("\r\n", "\n");
    let p_ip_norm = replace_path_both(
        replace_path_both(
            String::from_utf8_lossy(&p_ip.stdout).into_owned(),
            &prod_p,
            "PROD",
        ),
        &mod_pp,
        "MOD",
    )
    .replace("\r\n", "\n");
    assert_eq!(r_ip_norm, p_ip_norm);
}

#[test]
fn wrapper_forwarding_install_global_cursor_and_antigravity_match_powershell() {
    let tmp = TempDirGuard::new("global-diff");
    let b3_home = repo_root();
    let b3_home_str = b3_home.to_str().unwrap();
    let gl_ps = b3_home.join("adapters/install-global.ps1");

    let run_pair =
        |action: &str, rust_home: &Path, ps_home: &Path| -> ((i32, String), (i32, String)) {
            let r_cur = rust_home.join(".cursor");
            let r_ag = rust_home.join(".gemini/config/plugins/b3-ai-engineering");
            let p_cur = ps_home.join(".cursor");
            let p_ag = ps_home.join(".gemini/config/plugins/b3-ai-engineering");

            let r_out = Command::new(b3_bin())
                .env("USERPROFILE", rust_home)
                .args([
                    "install",
                    "global",
                    "--action",
                    action,
                    "--host",
                    "all",
                    "--b3-home",
                    b3_home_str,
                    "--cursor-home",
                    r_cur.to_str().unwrap(),
                    "--plugin-root",
                    r_ag.to_str().unwrap(),
                    "--user-home",
                    rust_home.to_str().unwrap(),
                ])
                .output()
                .unwrap();
            let p_out = Command::new("powershell")
                .env("B3_BIN", b3_bin())
                .env("USERPROFILE", ps_home)
                .arg("-NoProfile")
                .arg("-ExecutionPolicy")
                .arg("Bypass")
                .arg("-File")
                .arg(&gl_ps)
                .args([
                    "-Action",
                    action,
                    "-HostName",
                    "all",
                    "-B3Home",
                    b3_home_str,
                    "-CursorHome",
                    p_cur.to_str().unwrap(),
                    "-AntigravityPluginRoot",
                    p_ag.to_str().unwrap(),
                    "-UserHome",
                    ps_home.to_str().unwrap(),
                ])
                .output()
                .unwrap();
            let r_str = replace_path_fwd_both(
                replace_path_both(
                    String::from_utf8_lossy(&r_out.stdout).into_owned(),
                    rust_home,
                    "UHOME",
                ),
                rust_home,
                "UHOME_FWD",
            )
            .replace("\r\n", "\n");
            let p_str = replace_path_fwd_both(
                replace_path_both(
                    String::from_utf8_lossy(&p_out.stdout).into_owned(),
                    ps_home,
                    "UHOME",
                ),
                ps_home,
                "UHOME_FWD",
            )
            .replace("\r\n", "\n");
            (
                (r_out.status.code().unwrap_or(-1), r_str),
                (p_out.status.code().unwrap_or(-1), p_str),
            )
        };

    let uh_r = tmp.path.join("home-rust");
    let uh_p = tmp.path.join("home-ps");
    fs::create_dir_all(&uh_r).unwrap();
    fs::create_dir_all(&uh_p).unwrap();

    for action in ["install", "verify", "update", "uninstall"] {
        let ((rc, ro), (pc, po)) = run_pair(action, &uh_r, &uh_p);
        assert_eq!(rc, 0, "rust failed for {action}: {ro}");
        assert_eq!(pc, 0, "ps failed for {action}: {po}");
        assert_eq!(ro, po, "stdout mismatch for action={action}");
    }
}
