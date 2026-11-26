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

fn run_b3(args: &[&str]) -> (i32, String) {
    let out = Command::new(b3_bin())
        .args(args)
        .output()
        .expect("run b3 binary");
    (out.status.code().unwrap_or(-1), norm_lf(&out.stdout))
}

fn run_ps_script(script_rel: &str, args: &[&str]) -> (i32, String) {
    let script = repo_root().join(script_rel);
    let out: Output = Command::new("powershell")
        .env("B3_USE_LEGACY", "1")
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
fn differential_context_measure_strict_matches_powershell() {
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
fn differential_fingerprint_matches_powershell() {
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
fn differential_snapshot_matches_powershell_trees() {
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
fn differential_check_freshness_matches_powershell() {
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
fn differential_runs_lifecycle_and_link_guards() {
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
fn differential_verify_run_and_verify_check_match_powershell() {
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
fn differential_precommit_matches_powershell() {
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
fn differential_check_worktree_matches_powershell() {
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
