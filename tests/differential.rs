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
    }
}
