//! Cross-platform native golden parity and regression tests for `b3`.
//! Asserts independent legacy-contract golden exit codes, outputs, and on-disk
//! artifacts directly against `b3` with ZERO PowerShell dependency on Linux/macOS.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

static GOLDEN_SEQ: AtomicU64 = AtomicU64::new(0);

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
        let seq = GOLDEN_SEQ.fetch_add(1, Ordering::Relaxed);
        let dir =
            std::env::temp_dir().join(format!("b3-golden-{prefix}-{}-{seq}", std::process::id()));
        if dir.exists() {
            let _ = fs::remove_dir_all(&dir);
        }
        fs::create_dir_all(&dir).expect("create temp dir");
        Self { path: dir }
    }
}

impl Drop for TempDirGuard {
    fn drop(&mut self) {
        #[cfg(windows)]
        {
            // Clear NTFS reparse junctions without recursing into targets before removing temp tree.
            let _ = Command::new("cmd")
                .args([
                    "/d",
                    "/c",
                    &format!(
                        "for /d %d in (\"{}\") do @rmdir /s /q \"%d\" 2>nul",
                        self.path.display()
                    ),
                ])
                .status();
        }
        let _ = fs::remove_dir_all(&self.path);
    }
}

fn norm_lf(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes)
        .replace("\r\n", "\n")
        .trim_end_matches('\n')
        .to_string()
}

fn run_b3(args: &[&str]) -> (i32, String, String) {
    let out = Command::new(b3_bin())
        .args(args)
        .output()
        .expect("run b3 binary");
    (
        out.status.code().unwrap_or(-1),
        norm_lf(&out.stdout),
        norm_lf(&out.stderr),
    )
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
    git_in(dir, &["symbolic-ref", "HEAD", "refs/heads/main"]);
    git_in(dir, &["config", "user.email", "golden@example.com"]);
    git_in(dir, &["config", "user.name", "Golden Tester"]);
    git_in(dir, &["config", "core.autocrlf", "false"]);
    fs::create_dir_all(dir.join("src")).unwrap();
    fs::create_dir_all(dir.join("docs")).unwrap();
    fs::write(dir.join("src/app.txt"), "v1\n").unwrap();
    fs::write(dir.join("docs/guide.md"), "doc v1\n").unwrap();
    git_in(dir, &["add", "."]);
    git_in(dir, &["commit", "-m", "initial"]);
    git_in(dir, &["rev-parse", "HEAD"])
}

#[test]
fn golden_version_and_fingerprint_contracts() {
    let (v_code, v_out, _) = run_b3(&["--version"]);
    assert_eq!(v_code, 0);
    assert_eq!(v_out, concat!("b3 ", env!("CARGO_PKG_VERSION")));

    let (f_code, f_out, _) = run_b3(&[
        "guard",
        "fingerprint",
        "--depends-on",
        "T002,T001",
        "--scope",
        "src\\a.ts, src/b.ts",
        "--criteria",
        "AC1: ok",
        "--criteria",
        "AC2: done",
    ]);
    assert_eq!(f_code, 0);
    assert_eq!(
        f_out,
        "depends_on=T001,T002|scope=src\\a.ts, src/b.ts|acceptance_criteria=AC1: ok; AC2: done"
    );

    let (e_code, e_out, _) = run_b3(&["guard", "fingerprint", "--depends-on", "[]"]);
    assert_eq!(e_code, 1);
    assert!(e_out.contains("FINGERPRINT_FAIL:"), "out={e_out}");
}

#[test]
fn golden_context_measure_strict_within_budget() {
    let root = repo_root();
    let root_str = root.to_str().unwrap();
    let (code, out, _) = run_b3(&["context", "measure", "--repo-root", root_str, "--strict"]);
    assert_eq!(code, 0, "strict budget failed:\n{out}");
    assert!(out.contains("always_on_total   :"), "out={out}");
    assert!(out.contains("warnings          : 0"), "out={out}");
}

#[test]
fn golden_runs_snapshot_precommit_freshness_wave_and_verify() {
    let tmp = TempDirGuard::new("guard-core");
    let repo = &tmp.path;
    let base_sha = init_git_repo(repo);
    let r = repo.to_str().unwrap();

    // Runs lifecycle
    let (c, run_id, _) = run_b3(&[
        "guard",
        "new-run",
        "--repo-root",
        r,
        "--slug",
        "my feature",
        "--timestamp",
        "20261126-1015",
    ]);
    assert_eq!(c, 0);
    assert_eq!(run_id, "20261126-1015-my-feature");
    assert!(repo.join(".b3/ship/CURRENT").is_file());

    let (c_res, out_res, _) = run_b3(&["guard", "resolve-run", "--repo-root", r]);
    assert_eq!(c_res, 0);
    assert_eq!(out_res, ".b3/ship/runs/20261126-1015-my-feature");

    let (c_list, out_list, _) = run_b3(&["guard", "list-runs", "--repo-root", r]);
    assert_eq!(c_list, 0);
    assert!(
        out_list.contains("* 20261126-1015-my-feature ["),
        "list={out_list}"
    );

    // Snapshot & secret fail-closed
    let (c_snap, sha_snap, _) = run_b3(&["guard", "snapshot", "--repo-root", r]);
    assert_eq!(c_snap, 0);
    assert_eq!(sha_snap.len(), 40);
    assert!(sha_snap.bytes().all(|b| b.is_ascii_hexdigit()));
    assert_eq!(git_in(repo, &["stash", "list"]), "");

    fs::write(repo.join(".env"), "SECRET=1\n").unwrap();
    let (c_sec, out_sec, _) = run_b3(&["guard", "snapshot", "--repo-root", r]);
    assert_eq!(c_sec, 1);
    assert!(out_sec.contains("SNAPSHOT_FAIL:"), "out={out_sec}");
    fs::remove_file(repo.join(".env")).unwrap();

    // Precommit allowed-paths enforcement
    fs::write(repo.join("src/app.txt"), "v2\n").unwrap();
    git_in(repo, &["add", "src/app.txt"]);
    let (c_pc_bad, out_pc_bad, _) = run_b3(&[
        "guard",
        "precommit",
        "--repo-root",
        r,
        "--allowed-paths",
        "docs/guide.md",
    ]);
    assert_eq!(c_pc_bad, 1);
    assert!(out_pc_bad.contains("PRECOMMIT_FAIL:"), "out={out_pc_bad}");

    // Verify-run & verify-check
    let (c_vr, out_vr, _) = run_b3(&[
        "guard",
        "verify-run",
        "--repo-root",
        r,
        "--verify-cmd",
        "echo verified-ok",
        "--receipt-path",
        ".b3/ship/v1.verify",
        "--task-id",
        "T001",
        "--relevant-paths",
        "src/app.txt",
    ]);
    assert_eq!(c_vr, 0, "verify-run failed: {out_vr}");
    assert!(out_vr.starts_with("VERIFY_PASS: exit=0 "), "out={out_vr}");
    let receipt_txt = fs::read_to_string(repo.join(".b3/ship/v1.verify")).unwrap();
    assert!(receipt_txt.contains("schema=b3-verify-v1\n"));
    assert!(receipt_txt.contains("status=PASS\n"));
    assert!(receipt_txt.contains(&format!("head_sha={base_sha}\n")));

    let (c_vc, out_vc, _) = run_b3(&[
        "guard",
        "verify-check",
        "--repo-root",
        r,
        "--receipt-path",
        ".b3/ship/v1.verify",
        "--relevant-paths",
        "src/app.txt",
    ]);
    assert_eq!(c_vc, 0);
    assert!(out_vc.starts_with("VERIFY_VALID:"), "out={out_vc}");

    let (c_pc_ok, out_pc_ok, _) = run_b3(&[
        "guard",
        "precommit",
        "--repo-root",
        r,
        "--allowed-paths",
        "src/app.txt",
        "--require-verify-receipt",
        ".b3/ship/v1.verify",
    ]);
    assert_eq!(c_pc_ok, 0, "precommit failed: {out_pc_ok}");
    assert!(out_pc_ok.starts_with("PRECOMMIT_OK"), "out={out_pc_ok}");

    // Freshness & Wave checks
    let (c_fr, out_fr, _) = run_b3(&[
        "guard",
        "check-freshness",
        "--repo-root",
        r,
        "--approach-at-sha",
        &base_sha,
        "--task-base-sha",
        &base_sha,
        "--watched-paths",
        "docs/guide.md",
        "--owned-files",
        "src/app.txt",
    ]);
    assert_eq!(c_fr, 0, "check-freshness failed: {out_fr}");
    assert!(out_fr.starts_with("FRESH"), "out={out_fr}");

    let (c_w1, out_w1, _) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r,
        "--wave-specs",
        "T1=src/a.txt;T2=docs/b.md;T3=none",
    ]);
    assert_eq!(c_w1, 0, "check-wave disjoint failed: {out_w1}");
    assert!(out_w1.contains("WAVE_OK: disjoint"), "out={out_w1}");

    let (c_w2, out_w2, _) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r,
        "--wave-specs",
        "T1=src/shared.txt;T2=src/shared.txt;T3=docs/c.md",
        "--partition",
        "--max-concurrency",
        "2",
    ]);
    assert_eq!(c_w2, 0, "check-wave partition failed: {out_w2}");
    assert!(out_w2.contains("WAVE_PARTITIONED:"), "out={out_w2}");

    let (c_w3, out_w3, _) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r,
        "--wave-specs",
        "T1=src/shared.txt;T2=src/shared.txt",
        "--partition",
    ]);
    assert_eq!(c_w3, 2, "expected WAVE_SEQUENTIAL exit 2: {out_w3}");
    assert!(out_w3.contains("WAVE_SEQUENTIAL:"), "out={out_w3}");
}

#[test]
fn golden_ledger_merge_policy_mechanical_symbol_and_cache() {
    let tmp = TempDirGuard::new("governance");
    let repo = &tmp.path;
    let base_sha = init_git_repo(repo);
    fs::create_dir_all(repo.join(".b3")).unwrap();
    fs::create_dir_all(repo.join("releases")).unwrap();
    fs::write(
        repo.join(".b3/research-policy.json"),
        "{\"auto_merge\":\"authorized\",\"protected_paths\":[\"releases/\"],\"allow_protected_paths\":false,\"require_ci\":true,\"require_review\":true}\n",
    )
    .unwrap();
    git_in(repo, &["add", ".b3/research-policy.json"]);
    git_in(repo, &["commit", "-m", "add policy on main"]);
    let trunk_sha = git_in(repo, &["rev-parse", "HEAD"]);

    git_in(repo, &["checkout", "-b", "feat/work", &trunk_sha]);
    fs::write(repo.join("docs/notes.md"), "clean doc\n").unwrap();
    git_in(repo, &["add", "docs/notes.md"]);
    git_in(repo, &["commit", "-m", "add safe note"]);
    let head_sha = git_in(repo, &["rev-parse", "HEAD"]);
    let r = repo.to_str().unwrap();

    // Receipt + independent ledger -> local merge authorized
    let (vc, vout, _) = run_b3(&[
        "guard",
        "verify-run",
        "--repo-root",
        r,
        "--verify-cmd",
        "echo ok",
        "--receipt-path",
        ".b3/ship/head.verify",
        "--task-id",
        "U01",
    ]);
    assert_eq!(vc, 0, "verify-run failed: {vout}");

    let led = ".b3/ship/ledger.md";
    let (lc_init, _, _) = run_b3(&[
        "guard",
        "review-ledger",
        "--repo-root",
        r,
        "--action",
        "init",
        "--ledger-path",
        led,
        "--base-sha",
        &trunk_sha,
        "--review-independence",
        "INDEPENDENT",
    ]);
    assert_eq!(lc_init, 0);
    let (lc_upd, _, _) = run_b3(&[
        "guard",
        "review-ledger",
        "--repo-root",
        r,
        "--action",
        "update",
        "--ledger-path",
        led,
        "--unit-id",
        "U01",
        "--status",
        "REVIEWED",
        "--receipt-path",
        ".b3/ship/head.verify",
    ]);
    assert_eq!(lc_upd, 0);

    let (mp_ok, mp_ok_out, _) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        r,
        "--ledger-path",
        led,
        "--receipt-path",
        ".b3/ship/head.verify",
    ]);
    assert_eq!(mp_ok, 0, "merge-policy failed: {mp_ok_out}");
    assert_eq!(
        mp_ok_out,
        format!(
            "MERGE_AUTHORIZED: mode=local target_ref=refs/heads/main target_sha={trunk_sha} head_sha={head_sha} policy_authority=refs/heads/main@{trunk_sha} auto_merge=authorized governance=CLEAR"
        )
    );

    // Caller-reported PASS alone (without a canonical verify_receipt) must never authorize
    let led_norec = ".b3/ship/ledger_norec.md";
    let (li2, _, _) = run_b3(&[
        "guard",
        "review-ledger",
        "--repo-root",
        r,
        "--action",
        "init",
        "--ledger-path",
        led_norec,
        "--base-sha",
        &trunk_sha,
        "--review-independence",
        "INDEPENDENT",
    ]);
    assert_eq!(li2, 0);
    let (lu2, _, _) = run_b3(&[
        "guard",
        "review-ledger",
        "--repo-root",
        r,
        "--action",
        "update",
        "--ledger-path",
        led_norec,
        "--unit-id",
        "U01",
        "--status",
        "REVIEWED",
    ]);
    assert_eq!(lu2, 0);
    let (mp_bad_ci, mp_bad_ci_out, _) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        r,
        "--ledger-path",
        led_norec,
        "--ci-status",
        "PASS",
        "--changed-paths",
        "docs/notes.md",
    ]);
    assert_eq!(
        mp_bad_ci, 1,
        "expected block without verify_receipt: {mp_bad_ci_out}"
    );
    assert!(
        mp_bad_ci_out.starts_with("MERGE_BLOCKED: ci_evidence_"),
        "out={mp_bad_ci_out}"
    );

    // Evidence + context-cache + diff-scope + review-inventory
    let (ev_w, ev_w_out, _) = run_b3(&[
        "guard",
        "evidence-check",
        "--repo-root",
        r,
        "--write-manifest",
        "--manifest-path",
        ".b3/ship/ev.manifest",
        "--source-paths",
        "docs/notes.md",
    ]);
    assert_eq!(ev_w, 0);
    assert!(ev_w_out.starts_with("EVIDENCE_WRITTEN:"), "out={ev_w_out}");
    let (ev_c, ev_c_out, _) = run_b3(&[
        "guard",
        "evidence-check",
        "--repo-root",
        r,
        "--manifest-path",
        ".b3/ship/ev.manifest",
    ]);
    assert_eq!(ev_c, 0);
    assert!(ev_c_out.starts_with("EVIDENCE_FRESH:"), "out={ev_c_out}");

    let (cc_r, cc_r_out, _) = run_b3(&[
        "guard",
        "context-cache",
        "--repo-root",
        r,
        "--action",
        "record",
        "--cache-path",
        ".b3/ship/ctx.cache",
        "--scope-id",
        "T1",
        "--anchor-paths",
        "docs/notes.md",
        "--scope-paths",
        "src/app.txt",
    ]);
    assert_eq!(cc_r, 0);
    assert!(cc_r_out.starts_with("CONTEXT_RECORDED:"), "out={cc_r_out}");
    let (cc_c, cc_c_out, _) = run_b3(&[
        "guard",
        "context-cache",
        "--repo-root",
        r,
        "--action",
        "check",
        "--cache-path",
        ".b3/ship/ctx.cache",
        "--scope-id",
        "T1",
        "--anchor-paths",
        "docs/notes.md",
        "--scope-paths",
        "src/app.txt",
    ]);
    assert_eq!(cc_c, 0);
    assert!(cc_c_out.contains("CONTEXT_FRESH:"), "out={cc_c_out}");

    // R008 regressions: mechanical-check does not false-trigger on src/guard/mechanical.rs,
    // and symbol-check skips #[test] functions while catching dead non-test functions.
    fs::copy(
        repo_root().join("src/guard/mechanical.rs"),
        repo.join("src/mechanical_self.rs"),
    )
    .unwrap();
    let (mc_self, mc_self_out, _) = run_b3(&[
        "guard",
        "mechanical-check",
        "--repo-root",
        r,
        "--base-sha",
        &base_sha,
        "--allowed-paths",
        ".",
    ]);
    assert_eq!(
        mc_self, 0,
        "mechanical.rs must not self-match its own leftover scanner: {mc_self_out}"
    );
    assert!(
        !mc_self_out.contains("src/mechanical_self.rs:"),
        "mechanical.rs must not self-match its own leftover scanner: {mc_self_out}"
    );
    fs::remove_file(repo.join("src/mechanical_self.rs")).unwrap();

    let rs_code = r#"
#[test]
fn unit_test_should_not_be_orphan() {
    assert_eq!(1 + 1, 2);
}

fn dead_non_test_helper() -> i32 {
    42
}
"#;
    fs::write(repo.join("src/mod_check.rs"), rs_code).unwrap();
    let (sym_c, sym_out, _) = run_b3(&[
        "guard",
        "symbol-check",
        "--repo-root",
        r,
        "--base-sha",
        &base_sha,
    ]);
    assert_eq!(sym_c, 2, "expected dead_non_test_helper finding: {sym_out}");
    assert!(
        sym_out.contains("dead_non_test_helper"),
        "missing real dead helper: {sym_out}"
    );
    assert!(
        !sym_out.contains("unit_test_should_not_be_orphan"),
        "#[test] fn must not be reported as orphan_internal: {sym_out}"
    );
}

#[cfg(windows)]
fn create_dir_junction(link: &Path, target: &Path) {
    let out = Command::new("cmd")
        .args([
            "/d",
            "/c",
            "mklink",
            "/J",
            &link.to_string_lossy(),
            &target.to_string_lossy(),
        ])
        .output()
        .expect("run mklink /J");
    assert!(
        out.status.success(),
        "mklink /J failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}

#[test]
fn golden_install_product_sync_and_r006_symlink_guards() {
    let b3_home = repo_root();
    let b3_home_str = b3_home.to_str().unwrap();

    // Happy-path install product -> cursor
    let prod_tmp = TempDirGuard::new("prod-ok");
    init_git_repo(&prod_tmp.path);
    let (ic, iout, _) = run_b3(&[
        "install",
        "product",
        "--product-root",
        prod_tmp.path.to_str().unwrap(),
        "--b3-home",
        b3_home_str,
        "--host",
        "cursor",
    ]);
    assert_eq!(ic, 0, "install product failed: {iout}");
    assert!(prod_tmp.path.join(".b3/home").is_file());
    assert!(prod_tmp.path.join(".cursor/commands/b3-ship.md").is_file());
    let gi = fs::read_to_string(prod_tmp.path.join(".gitignore")).unwrap();
    assert!(gi.contains(".b3/ship/"));

    // R006 regression: symlink/junction parent directories must be rejected before writes
    let ext_tmp = TempDirGuard::new("ext-target");
    fs::write(ext_tmp.path.join("sentinel.txt"), "untouched\n").unwrap();

    let bad_prod = TempDirGuard::new("prod-link");
    init_git_repo(&bad_prod.path);
    let agents_dir = bad_prod.path.join(".agents");
    #[cfg(unix)]
    std::os::unix::fs::symlink(&ext_tmp.path, &agents_dir).unwrap();
    #[cfg(windows)]
    create_dir_junction(&agents_dir, &ext_tmp.path);

    let (bc, bout, _) = run_b3(&[
        "install",
        "product",
        "--product-root",
        bad_prod.path.to_str().unwrap(),
        "--b3-home",
        b3_home_str,
        "--host",
        "codex",
    ]);
    assert_ne!(bc, 0, "symlink/junction .agents must be refused: {bout}");
    assert_eq!(
        fs::read_to_string(ext_tmp.path.join("sentinel.txt")).unwrap(),
        "untouched\n"
    );

    // Unix file-symlink tests (plus Windows when Developer Mode allows file symlinks)
    let file_link_prod = TempDirGuard::new("prod-file-link");
    init_git_repo(&file_link_prod.path);
    let ext_gi = ext_tmp.path.join("external_gi");
    fs::write(&ext_gi, "preserve-me\n").unwrap();
    let link_gi = file_link_prod.path.join(".gitignore");
    let created_file_link = {
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(&ext_gi, &link_gi).is_ok()
        }
        #[cfg(windows)]
        {
            std::os::windows::fs::symlink_file(&ext_gi, &link_gi).is_ok()
        }
    };
    if created_file_link {
        let (fc, fout, _) = run_b3(&[
            "install",
            "product",
            "--product-root",
            file_link_prod.path.to_str().unwrap(),
            "--b3-home",
            b3_home_str,
            "--host",
            "cursor",
        ]);
        assert_ne!(fc, 0, "symlink .gitignore must be refused: {fout}");
        assert_eq!(fs::read_to_string(&ext_gi).unwrap(), "preserve-me\n");
    }

    // R006 sync regression: junctioned .agents dir blocks `sync --host antigravity`
    let sync_repo = TempDirGuard::new("sync-link");
    fs::create_dir_all(sync_repo.path.join("skills/demo/hello")).unwrap();
    fs::write(
        sync_repo.path.join("skills/demo/hello/SKILL.md"),
        "---\nname: hello\ndescription: demo\n---\n",
    )
    .unwrap();
    #[cfg(unix)]
    std::os::unix::fs::symlink(&ext_tmp.path, sync_repo.path.join(".agents")).unwrap();
    #[cfg(windows)]
    create_dir_junction(&sync_repo.path.join(".agents"), &ext_tmp.path);

    let (sc, sout, _) = run_b3(&[
        "sync",
        "--repo-root",
        sync_repo.path.to_str().unwrap(),
        "--host",
        "antigravity",
    ]);
    assert_ne!(sc, 0, "junctioned .agents must be refused by sync: {sout}");
    assert!(!ext_tmp.path.join("skills.json").exists());
}

fn sha256_file_hex_for_test(path: &Path) -> String {
    // Use Git's deterministic SHA-256 via `certutil`/`sha256sum`? Use our crate helper!
    let bytes = fs::read(path).expect("read artifact");
    b3::fs::sha256_bytes_hex(&bytes)
}

#[test]
fn golden_bootstrap_checksum_and_rollback() {
    let root = repo_root();
    let rel_tmp = TempDirGuard::new("bootstrap-rel");
    let inst_tmp = TempDirGuard::new("bootstrap-inst");

    let (target, artifact_name) = if cfg!(windows) {
        ("x86_64-pc-windows-msvc", "b3-x86_64-pc-windows-msvc.exe")
    } else if cfg!(target_os = "macos") && cfg!(target_arch = "aarch64") {
        ("aarch64-apple-darwin", "b3-aarch64-apple-darwin")
    } else if cfg!(target_os = "macos") {
        ("x86_64-apple-darwin", "b3-x86_64-apple-darwin")
    } else {
        ("x86_64-unknown-linux-gnu", "b3-x86_64-unknown-linux-gnu")
    };

    let artifact_path = rel_tmp.path.join(artifact_name);
    fs::copy(b3_bin(), &artifact_path).expect("copy b3 binary");
    let real_sha = sha256_file_hex_for_test(&artifact_path);
    fs::write(
        rel_tmp.path.join("SHA256SUMS.txt"),
        format!("{real_sha}  {artifact_name}\n"),
    )
    .unwrap();

    let dest_name = if cfg!(windows) { "b3.exe" } else { "b3" };
    let dest_bin = inst_tmp.path.join(dest_name);
    // Seed a distinct prior binary to verify backup + rollback cleanly
    fs::write(&dest_bin, b"PRIOR_BINARY_SENTINEL").unwrap();

    let run_boot = |extra: &[&str]| -> (i32, String, String) {
        #[cfg(windows)]
        {
            let script = root.join("scripts/bootstrap-b3.ps1");
            let mut args = vec![
                "-NoProfile".to_string(),
                "-ExecutionPolicy".to_string(),
                "Bypass".to_string(),
                "-File".to_string(),
                script.to_string_lossy().into_owned(),
                "-ReleaseDir".to_string(),
                rel_tmp.path.to_string_lossy().into_owned(),
                "-InstallDir".to_string(),
                inst_tmp.path.to_string_lossy().into_owned(),
                "-Target".to_string(),
                target.to_string(),
            ];
            for e in extra {
                args.push((*e).to_string());
            }
            let out = Command::new("powershell").args(&args).output().unwrap();
            (
                out.status.code().unwrap_or(-1),
                norm_lf(&out.stdout),
                norm_lf(&out.stderr),
            )
        }
        #[cfg(not(windows))]
        {
            let script = root.join("scripts/bootstrap-b3.sh");
            let mut args = vec![
                script.to_string_lossy().into_owned(),
                "--release-dir".to_string(),
                rel_tmp.path.to_string_lossy().into_owned(),
                "--install-dir".to_string(),
                inst_tmp.path.to_string_lossy().into_owned(),
                "--target".to_string(),
                target.to_string(),
            ];
            for e in extra {
                args.push((*e).to_string());
            }
            let out = Command::new("bash").args(&args).output().unwrap();
            (
                out.status.code().unwrap_or(-1),
                norm_lf(&out.stdout),
                norm_lf(&out.stderr),
            )
        }
    };

    // 1. Corrupted checksum must fail closed without overwriting existing binary
    fs::write(
        rel_tmp.path.join("SHA256SUMS.txt"),
        format!("{}{artifact_name}\n", "0".repeat(64) + "  "),
    )
    .unwrap();
    let (bad_ec, _, bad_err) = run_boot(&[]);
    assert_ne!(bad_ec, 0, "corrupt checksum must fail closed");
    assert!(
        bad_err.to_ascii_lowercase().contains("checksum")
            || bad_err.to_ascii_lowercase().contains("sha256"),
        "err={bad_err}"
    );
    assert_eq!(fs::read(&dest_bin).unwrap(), b"PRIOR_BINARY_SENTINEL");

    // 2. Valid checksum installs, backs up .prev, and verifies `--version`
    fs::write(
        rel_tmp.path.join("SHA256SUMS.txt"),
        format!("{real_sha}  {artifact_name}\n"),
    )
    .unwrap();
    let (ok_ec, ok_out, ok_err) = run_boot(&[]);
    assert_eq!(ok_ec, 0, "bootstrap install failed:\n{ok_out}\n{ok_err}");
    assert!(ok_out.contains("BOOTSTRAP_OK:"), "out={ok_out}");
    assert_eq!(
        fs::read(inst_tmp.path.join(format!("{dest_name}.prev"))).unwrap(),
        b"PRIOR_BINARY_SENTINEL"
    );

    let (ver_c, ver_out, _) = {
        let out = Command::new(&dest_bin).arg("--version").output().unwrap();
        (
            out.status.code().unwrap_or(-1),
            norm_lf(&out.stdout),
            norm_lf(&out.stderr),
        )
    };
    assert_eq!(ver_c, 0);
    assert_eq!(ver_out, concat!("b3 ", env!("CARGO_PKG_VERSION")));

    // 3. Rollback restores .prev sentinel
    let rb_flag = if cfg!(windows) {
        "-Rollback"
    } else {
        "--rollback"
    };
    let (rb_ec, rb_out, rb_err) = run_boot(&[rb_flag]);
    assert_eq!(rb_ec, 0, "rollback failed:\n{rb_out}\n{rb_err}");
    assert!(rb_out.contains("ROLLBACK_OK:"), "out={rb_out}");
    assert_eq!(fs::read(&dest_bin).unwrap(), b"PRIOR_BINARY_SENTINEL");
}

#[cfg(unix)]
#[test]
fn unix_shell_wrapper_forwarding() {
    let root = repo_root();
    let root_str = root.to_str().unwrap();
    let run_sh = |rel: &str, args: &[&str]| -> (i32, String) {
        let out = Command::new("bash")
            .env("B3_BIN", b3_bin())
            .arg(root.join(rel))
            .args(args)
            .output()
            .expect("run sh wrapper");
        (out.status.code().unwrap_or(-1), norm_lf(&out.stdout))
    };

    let (c_ctx, out_ctx) = run_sh(
        "scripts/measure-context.sh",
        &["--repo-root", root_str, "--strict"],
    );
    assert_eq!(c_ctx, 0);
    assert!(out_ctx.contains("warnings=0"), "out={out_ctx}");

    let (c_fp, out_fp) = run_sh(
        "scripts/b3-guard.sh",
        &[
            "fingerprint",
            "--depends-on",
            "T002,T001",
            "--scope",
            "src/a.ts",
            "--criteria",
            "AC1: ok",
        ],
    );
    assert_eq!(c_fp, 0);
    assert_eq!(
        out_fp,
        "depends_on=T001,T002|scope=src/a.ts|acceptance_criteria=AC1: ok"
    );
}
