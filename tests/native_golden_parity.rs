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

struct LegacyBaselineCase {
    id: String,
    contract_family: String,
    status_label: String,
    legacy_exit_code: i32,
    legacy_stdout_normalized: String,
}

fn load_legacy_baseline() -> (String, Vec<LegacyBaselineCase>) {
    let raw = include_str!("fixtures/legacy_baseline_65eaaae.json");
    let root = b3::json::parse_json(raw).expect("parse legacy_baseline_65eaaae.json");
    let sha = root
        .get("baseline_sha")
        .and_then(|v| v.as_str())
        .expect("baseline_sha")
        .to_string();
    assert_eq!(sha, "65eaaaeb275ee1ce89c57d6fdd78ac3f3c1932fe");
    let arr = root
        .get("cases")
        .and_then(|v| v.as_array())
        .expect("cases array");
    let mut out = Vec::with_capacity(arr.len());
    for item in arr {
        out.push(LegacyBaselineCase {
            id: item
                .get("id")
                .and_then(|v| v.as_str())
                .expect("case id")
                .to_string(),
            contract_family: item
                .get("contract_family")
                .and_then(|v| v.as_str())
                .expect("contract_family")
                .to_string(),
            status_label: item
                .get("status_label")
                .and_then(|v| v.as_str())
                .expect("status_label")
                .to_string(),
            legacy_exit_code: item
                .get("legacy_exit_code")
                .and_then(|v| v.as_i64())
                .expect("legacy_exit_code") as i32,
            legacy_stdout_normalized: item
                .get("legacy_stdout_normalized")
                .and_then(|v| v.as_str())
                .expect("legacy_stdout_normalized")
                .to_string(),
        });
    }
    (sha, out)
}

fn find_legacy_case<'a>(cases: &'a [LegacyBaselineCase], id: &str) -> &'a LegacyBaselineCase {
    cases
        .iter()
        .find(|c| c.id == id)
        .unwrap_or_else(|| panic!("missing legacy baseline case: {id}"))
}

fn replace_path_variants(mut s: String, raw: &Path, token: &str) -> String {
    let mut candidates = Vec::new();
    let raw_str = raw.to_string_lossy().into_owned();
    candidates.push(raw_str);
    if let Ok(canon) = fs::canonicalize(raw) {
        let cs = canon.to_string_lossy().into_owned();
        let trimmed = cs.strip_prefix("\\\\?\\").unwrap_or(&cs).to_string();
        candidates.push(trimmed);
    }
    for base in candidates {
        let fwd = base.replace('\\', "/");
        let low = fwd.to_ascii_lowercase();
        for v in [base, fwd, low] {
            if !v.is_empty() {
                s = s.replace(v.as_str(), token);
            }
        }
    }
    s
}

fn normalize_dynamic_tokens(mut s: String, replacers: &[(&str, &str)]) -> String {
    for (token, val) in replacers {
        if !val.is_empty() {
            s = s.replace(val, token);
            let fwd = val.replace('\\', "/");
            s = s.replace(&fwd, token);
        }
    }
    if let Some(idx) = s.find("duration_ms=") {
        let rest = &s[idx + "duration_ms=".len()..];
        let digits = rest.bytes().take_while(|b| b.is_ascii_digit()).count();
        if digits > 0 {
            let tail = &rest[digits..];
            s = format!("{}duration_ms=<DURATION_MS>{tail}", &s[..idx]);
        }
    }
    s
}

fn run_b3_with_env(
    args: &[&str],
    cwd: Option<&Path>,
    envs: &[(&str, &str)],
) -> (i32, String, String) {
    let mut cmd = Command::new(b3_bin());
    cmd.args(args);
    if let Some(dir) = cwd {
        cmd.current_dir(dir);
    }
    for (k, v) in envs {
        cmd.env(k, v);
    }
    let out = cmd.output().expect("run b3 binary");
    (
        out.status.code().unwrap_or(-1),
        norm_lf(&out.stdout),
        norm_lf(&out.stderr),
    )
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
    // Seed a valid runnable prior binary (copy of b3_bin) so rollback smoke checks (`--version`) succeed
    fs::copy(b3_bin(), &dest_bin).expect("seed runnable prior binary");
    let prior_bytes = fs::read(&dest_bin).expect("read prior binary");

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
    assert_eq!(fs::read(&dest_bin).unwrap(), prior_bytes);

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
        prior_bytes
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

    // 3. Rollback restores .prev binary and passes version check
    let rb_flag = if cfg!(windows) {
        "-Rollback"
    } else {
        "--rollback"
    };
    let (rb_ec, rb_out, rb_err) = run_boot(&[rb_flag]);
    assert_eq!(rb_ec, 0, "rollback failed:\n{rb_out}\n{rb_err}");
    assert!(rb_out.contains("ROLLBACK_OK:"), "out={rb_out}");
    assert_eq!(fs::read(&dest_bin).unwrap(), prior_bytes);
    let rb_ver = Command::new(&dest_bin).arg("--version").output().unwrap();
    assert!(rb_ver.status.success());
    assert_eq!(
        norm_lf(&rb_ver.stdout),
        concat!("b3 ", env!("CARGO_PKG_VERSION"))
    );
}

#[test]
fn golden_legacy_baseline_65eaaae_contracts() {
    let (sha, cases) = load_legacy_baseline();
    assert_eq!(sha, "65eaaaeb275ee1ce89c57d6fdd78ac3f3c1932fe");
    assert_eq!(cases.len(), 47);

    // 1. Fingerprints & Snapshots
    let c_fp = find_legacy_case(&cases, "fp_canonical");
    assert_eq!(c_fp.contract_family, "1_tree_and_task_fingerprints");
    assert_eq!(c_fp.status_label, "INDEPENDENT_LEGACY_PARITY");
    let (ec, out, _) = run_b3(&[
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
    assert_eq!(ec, c_fp.legacy_exit_code);
    assert_eq!(out, c_fp.legacy_stdout_normalized);

    let c_fp_empty = find_legacy_case(&cases, "fp_empty_depends");
    let (ec, out, _) = run_b3(&[
        "guard",
        "fingerprint",
        "--depends-on",
        "[]",
        "--scope",
        "src/a.ts",
        "--criteria",
        "AC1: ok",
    ]);
    assert_eq!(ec, c_fp_empty.legacy_exit_code);
    assert_eq!(out, c_fp_empty.legacy_stdout_normalized);

    let c_fp_miss = find_legacy_case(&cases, "fp_missing_scope");
    assert_eq!(c_fp_miss.status_label, "INTENTIONAL_BEHAVIOR_CHANGE");
    let (ec, out, _) = run_b3(&["guard", "fingerprint", "--depends-on", "[]"]);
    assert_eq!(ec, c_fp_miss.legacy_exit_code);
    assert_eq!(out, "FINGERPRINT_FAIL: missing --scope");

    // 2. Verification Receipts
    let tmp2 = TempDirGuard::new("leg-f2");
    let base2 = init_git_repo(&tmp2.path);
    let r2 = tmp2.path.to_str().unwrap();

    let (ec, out, _) = run_b3(&[
        "guard",
        "verify-run",
        "--repo-root",
        r2,
        "--verify-cmd",
        "echo verified-ok",
        "--receipt-path",
        ".b3/ship/v1.verify",
        "--task-id",
        "T001",
        "--relevant-paths",
        "src/app.txt",
    ]);
    let c_vr = find_legacy_case(&cases, "verify_run_schema");
    assert_eq!(ec, c_vr.legacy_exit_code);
    assert_eq!(
        normalize_dynamic_tokens(out, &[("<HEAD_SHA>", &base2)]),
        c_vr.legacy_stdout_normalized
    );

    let c_vc_ok = find_legacy_case(&cases, "verify_check_valid");
    let (ec, out, _) = run_b3(&[
        "guard",
        "verify-check",
        "--repo-root",
        r2,
        "--receipt-path",
        ".b3/ship/v1.verify",
        "--relevant-paths",
        "src/app.txt",
    ]);
    assert_eq!(ec, c_vc_ok.legacy_exit_code);
    assert_eq!(out, c_vc_ok.legacy_stdout_normalized);

    let c_vc_cmd = find_legacy_case(&cases, "verify_check_cmd_mismatch");
    let (ec, out, _) = run_b3(&[
        "guard",
        "verify-check",
        "--repo-root",
        r2,
        "--receipt-path",
        ".b3/ship/v1.verify",
        "--expected-cmd",
        "echo other",
    ]);
    assert_eq!(ec, c_vc_cmd.legacy_exit_code);
    assert_eq!(out, c_vc_cmd.legacy_stdout_normalized);

    let c_vc_tgt_ok = find_legacy_case(&cases, "verify_check_target_commit_sha_valid");
    let (ec, out, _) = run_b3(&[
        "guard",
        "verify-check",
        "--repo-root",
        r2,
        "--receipt-path",
        ".b3/ship/v1.verify",
        "--relevant-paths",
        "src/app.txt",
        "--target-commit-sha",
        &base2,
    ]);
    assert_eq!(ec, c_vc_tgt_ok.legacy_exit_code);
    assert_eq!(out, c_vc_tgt_ok.legacy_stdout_normalized);

    let c_vc_tgt_bad = find_legacy_case(&cases, "verify_check_target_commit_sha_mismatch");
    let (ec, out, _) = run_b3(&[
        "guard",
        "verify-check",
        "--repo-root",
        r2,
        "--receipt-path",
        ".b3/ship/v1.verify",
        "--relevant-paths",
        "src/app.txt",
        "--target-commit-sha",
        "0000000000000000000000000000000000000000",
    ]);
    assert_eq!(ec, c_vc_tgt_bad.legacy_exit_code);
    assert_eq!(out, c_vc_tgt_bad.legacy_stdout_normalized);

    fs::write(tmp2.path.join("src/app.txt"), "v2-mutated\n").unwrap();
    let c_vc_stale = find_legacy_case(&cases, "verify_check_stale");
    let (ec, out, _) = run_b3(&[
        "guard",
        "verify-check",
        "--repo-root",
        r2,
        "--receipt-path",
        ".b3/ship/v1.verify",
        "--relevant-paths",
        "src/app.txt",
    ]);
    assert_eq!(ec, c_vc_stale.legacy_exit_code);
    assert_eq!(out, c_vc_stale.legacy_stdout_normalized);

    // 3. Review Ledger (INDEPENDENT + SINGLE_AGENT_LIMIT)
    let tmp3 = TempDirGuard::new("leg-f3");
    let trunk3 = init_git_repo(&tmp3.path);
    let r3 = tmp3.path.to_str().unwrap();
    git_in(&tmp3.path, &["checkout", "-b", "feat/led"]);
    fs::write(tmp3.path.join("src/app.txt"), "v2\n").unwrap();
    git_in(&tmp3.path, &["add", "src/app.txt"]);
    git_in(&tmp3.path, &["commit", "-m", "feat"]);
    let head3 = git_in(&tmp3.path, &["rev-parse", "HEAD"]);
    let (vc, _, _) = run_b3(&[
        "guard",
        "verify-run",
        "--repo-root",
        r3,
        "--verify-cmd",
        "echo ok",
        "--receipt-path",
        ".b3/ship/u1.verify",
        "--task-id",
        "U01",
    ]);
    assert_eq!(vc, 0);

    let c_li = find_legacy_case(&cases, "ledger_init_independent");
    let (ec, out, _) = run_b3(&[
        "guard",
        "review-ledger",
        "--repo-root",
        r3,
        "--action",
        "init",
        "--ledger-path",
        ".b3/ship/ledger.md",
        "--base-sha",
        &trunk3,
        "--review-independence",
        "INDEPENDENT",
    ]);
    assert_eq!(ec, c_li.legacy_exit_code);
    assert_eq!(
        normalize_dynamic_tokens(out, &[("<HEAD_SHA>", &head3)]),
        c_li.legacy_stdout_normalized
    );

    let c_lu = find_legacy_case(&cases, "ledger_update_with_receipt");
    let (ec, out, _) = run_b3(&[
        "guard",
        "review-ledger",
        "--repo-root",
        r3,
        "--action",
        "update",
        "--ledger-path",
        ".b3/ship/ledger.md",
        "--unit-id",
        "U01",
        "--status",
        "REVIEWED",
        "--receipt-path",
        ".b3/ship/u1.verify",
    ]);
    assert_eq!(ec, c_lu.legacy_exit_code);
    assert_eq!(out, c_lu.legacy_stdout_normalized);

    let c_lc = find_legacy_case(&cases, "ledger_check_valid");
    let (ec, out, _) = run_b3(&[
        "guard",
        "review-ledger",
        "--repo-root",
        r3,
        "--action",
        "check",
        "--ledger-path",
        ".b3/ship/ledger.md",
    ]);
    assert_eq!(ec, c_lc.legacy_exit_code);
    assert_eq!(out, c_lc.legacy_stdout_normalized);

    let (ec, _, _) = run_b3(&[
        "guard",
        "review-ledger",
        "--repo-root",
        r3,
        "--action",
        "init",
        "--ledger-path",
        ".b3/ship/ledger-sal.md",
        "--base-sha",
        &trunk3,
        "--review-independence",
        "SINGLE_AGENT_LIMIT",
    ]);
    assert_eq!(ec, 0);
    let (ec, _, _) = run_b3(&[
        "guard",
        "review-ledger",
        "--repo-root",
        r3,
        "--action",
        "update",
        "--ledger-path",
        ".b3/ship/ledger-sal.md",
        "--unit-id",
        "U01",
        "--status",
        "REVIEWED",
        "--receipt-path",
        ".b3/ship/u1.verify",
    ]);
    assert_eq!(ec, 0);
    let c_sal = find_legacy_case(&cases, "ledger_check_single_agent_limit");
    let (ec, out, _) = run_b3(&[
        "guard",
        "review-ledger",
        "--repo-root",
        r3,
        "--action",
        "check",
        "--ledger-path",
        ".b3/ship/ledger-sal.md",
    ]);
    assert_eq!(ec, c_sal.legacy_exit_code);
    assert_eq!(out, c_sal.legacy_stdout_normalized);

    // 4. Worktree & Wave Ownership
    let tmp4 = TempDirGuard::new("leg-f4");
    let main4 = tmp4.path.join("main");
    let wt4 = tmp4.path.join("work");
    let peer4 = tmp4.path.join("peer");
    fs::create_dir_all(&main4).unwrap();
    let base4 = init_git_repo(&main4);
    git_in(
        &main4,
        &[
            "worktree",
            "add",
            "-b",
            "wt/work",
            wt4.to_str().unwrap(),
            &base4,
        ],
    );
    git_in(
        &main4,
        &[
            "worktree",
            "add",
            "-b",
            "wt/peer",
            peer4.to_str().unwrap(),
            &base4,
        ],
    );
    let c_wt_ok = find_legacy_case(&cases, "check_worktree_isolated");
    let (ec, out, _) = run_b3(&[
        "guard",
        "check-worktree",
        "--repo-root",
        wt4.to_str().unwrap(),
        "--expected-root",
        main4.to_str().unwrap(),
        "--expected-base-sha",
        &base4,
        "--peer-roots",
        peer4.to_str().unwrap(),
        "--require-isolated",
    ]);
    assert_eq!(ec, c_wt_ok.legacy_exit_code);
    let common4 = main4.join(".git");
    let norm_wt = replace_path_variants(out, &common4, "<COMMON_DIR>");
    let norm_wt = replace_path_variants(norm_wt, &wt4, "<WT_ROOT>");
    let norm_wt = normalize_dynamic_tokens(norm_wt, &[("<BASE_SHA>", &base4)]);
    assert_eq!(norm_wt, c_wt_ok.legacy_stdout_normalized);

    let c_wt_ov = find_legacy_case(&cases, "check_worktree_peer_overlap_blocked");
    let (ec, out, _) = run_b3(&[
        "guard",
        "check-worktree",
        "--repo-root",
        wt4.to_str().unwrap(),
        "--expected-root",
        wt4.to_str().unwrap(),
        "--peer-roots",
        wt4.to_str().unwrap(),
        "--require-isolated",
    ]);
    assert_eq!(ec, c_wt_ov.legacy_exit_code);
    let norm_ov = replace_path_variants(out, &wt4, "<WT_ROOT>");
    assert_eq!(norm_ov, c_wt_ov.legacy_stdout_normalized);

    for (id, specs, extra) in [
        (
            "check_wave_disjoint",
            "T1=src/a.txt;T2=docs/b.md;T3=none",
            &[][..],
        ),
        (
            "check_wave_partition",
            "T1=src/shared.txt;T2=src/shared.txt;T3=docs/c.md",
            &["--partition", "--max-concurrency", "2"][..],
        ),
        (
            "check_wave_sequential",
            "T1=src/shared.txt;T2=src/shared.txt",
            &["--partition"][..],
        ),
    ] {
        let c_w = find_legacy_case(&cases, id);
        let mut args = vec![
            "guard",
            "check-wave",
            "--repo-root",
            main4.to_str().unwrap(),
            "--wave-specs",
            specs,
        ];
        args.extend_from_slice(extra);
        let (ec, out, _) = run_b3(&args);
        assert_eq!(ec, c_w.legacy_exit_code, "case {id}: {out}");
        assert_eq!(out, c_w.legacy_stdout_normalized, "case {id}");
    }

    let c_fr = find_legacy_case(&cases, "check_freshness_fresh");
    let (ec, out, _) = run_b3(&[
        "guard",
        "check-freshness",
        "--repo-root",
        main4.to_str().unwrap(),
        "--approach-at-sha",
        &base4,
        "--task-base-sha",
        &base4,
        "--watched-paths",
        "docs/guide.md",
        "--owned-files",
        "src/app.txt",
    ]);
    assert_eq!(ec, c_fr.legacy_exit_code);
    assert_eq!(out, c_fr.legacy_stdout_normalized);

    // 5 & 6. Merge Policy, Protected Unicode/Space/Bracket Paths, Secret Paths, Precommit
    let tmp5 = TempDirGuard::new("leg-f5");
    init_git_repo(&tmp5.path);
    let r5 = tmp5.path.to_str().unwrap();
    fs::create_dir_all(tmp5.path.join(".b3")).unwrap();
    let prot_dir = tmp5.path.join("releases/v1 [draft] caf\u{00e9}");
    fs::create_dir_all(&prot_dir).unwrap();
    fs::write(
        tmp5.path.join(".b3/research-policy.json"),
        "{\"auto_merge\":\"authorized\",\"protected_paths\":[\"releases/\"],\"allow_protected_paths\":false,\"require_ci\":true,\"require_review\":true}\n",
    )
    .unwrap();
    fs::write(prot_dir.join("secret.txt"), "keep\n").unwrap();
    git_in(&tmp5.path, &["add", "-A"]);
    git_in(&tmp5.path, &["commit", "-m", "policy and protected seed"]);
    let trunk5 = git_in(&tmp5.path, &["rev-parse", "HEAD"]);

    git_in(&tmp5.path, &["checkout", "-b", "feat/work"]);
    fs::write(tmp5.path.join("docs/notes.md"), "clean doc\n").unwrap();
    git_in(&tmp5.path, &["add", "docs/notes.md"]);
    git_in(&tmp5.path, &["commit", "-m", "safe note"]);
    let head5 = git_in(&tmp5.path, &["rev-parse", "HEAD"]);
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            r5,
            "--verify-cmd",
            "echo ok",
            "--receipt-path",
            ".b3/ship/head.verify",
            "--task-id",
            "U01",
        ])
        .0,
        0
    );
    assert_eq!(
        run_b3(&[
            "guard",
            "review-ledger",
            "--repo-root",
            r5,
            "--action",
            "init",
            "--ledger-path",
            ".b3/ship/ledger.md",
            "--base-sha",
            &trunk5,
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
            r5,
            "--action",
            "update",
            "--ledger-path",
            ".b3/ship/ledger.md",
            "--unit-id",
            "U01",
            "--status",
            "REVIEWED",
            "--receipt-path",
            ".b3/ship/head.verify",
        ])
        .0,
        0
    );

    let c_mp_ok = find_legacy_case(&cases, "merge_policy_local_authorized");
    let (ec, out, _) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        r5,
        "--ledger-path",
        ".b3/ship/ledger.md",
        "--receipt-path",
        ".b3/ship/head.verify",
    ]);
    assert_eq!(ec, c_mp_ok.legacy_exit_code);
    assert_eq!(
        normalize_dynamic_tokens(out, &[("<TRUNK_SHA>", &trunk5), ("<HEAD_SHA>", &head5)]),
        c_mp_ok.legacy_stdout_normalized
    );

    assert_eq!(
        run_b3(&[
            "guard",
            "review-ledger",
            "--repo-root",
            r5,
            "--action",
            "init",
            "--ledger-path",
            ".b3/ship/ledger_norec.md",
            "--base-sha",
            &trunk5,
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
            r5,
            "--action",
            "update",
            "--ledger-path",
            ".b3/ship/ledger_norec.md",
            "--unit-id",
            "U01",
            "--status",
            "REVIEWED",
        ])
        .0,
        0
    );
    let c_mp_ci = find_legacy_case(
        &cases,
        "merge_policy_caller_ci_pass_without_receipt_blocked",
    );
    let (ec, out, _) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        r5,
        "--ledger-path",
        ".b3/ship/ledger_norec.md",
        "--ci-status",
        "PASS",
        "--changed-paths",
        "docs/notes.md",
    ]);
    assert_eq!(ec, c_mp_ci.legacy_exit_code);
    assert_eq!(out, c_mp_ci.legacy_stdout_normalized);

    fs::write(tmp5.path.join("docs/notes.md"), "clean doc v2\n").unwrap();
    git_in(&tmp5.path, &["add", "docs/notes.md"]);
    git_in(&tmp5.path, &["commit", "-m", "advance head"]);
    let head5b = git_in(&tmp5.path, &["rev-parse", "HEAD"]);
    let c_mp_st = find_legacy_case(&cases, "merge_policy_stale_ledger_blocked");
    let (ec, out, _) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        r5,
        "--ledger-path",
        ".b3/ship/ledger.md",
        "--receipt-path",
        ".b3/ship/head.verify",
    ]);
    assert_eq!(ec, c_mp_st.legacy_exit_code);
    assert_eq!(
        normalize_dynamic_tokens(
            out,
            &[
                ("<TRUNK_SHA>", &trunk5),
                ("<HEAD_SHA>", &head5b),
                ("<OLD_HEAD_SHA>", &head5),
            ]
        ),
        c_mp_st.legacy_stdout_normalized
    );

    fs::write(tmp5.path.join(".env"), "SECRET=1\n").unwrap();
    let c_sec = find_legacy_case(&cases, "snapshot_secret_env_blocked");
    let (ec, out, _) = run_b3(&["guard", "snapshot", "--repo-root", r5]);
    assert_eq!(ec, c_sec.legacy_exit_code);
    assert_eq!(out, c_sec.legacy_stdout_normalized);
    fs::remove_file(tmp5.path.join(".env")).unwrap();

    git_in(&tmp5.path, &["checkout", "-B", "feat/prot-add", &trunk5]);
    fs::write(prot_dir.join("new.txt"), "release\n").unwrap();
    git_in(&tmp5.path, &["add", "-A"]);
    git_in(&tmp5.path, &["commit", "-m", "add protected"]);
    let c_padd = find_legacy_case(&cases, "merge_policy_protected_unicode_space_bracket_add");
    assert_eq!(c_padd.status_label, "INTENTIONAL_BEHAVIOR_CHANGE");
    let (ec, out, _) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        r5,
        "--ledger-path",
        ".b3/ship/ledger.md",
        "--receipt-path",
        ".b3/ship/head.verify",
    ]);
    assert_eq!(ec, c_padd.legacy_exit_code);
    assert_eq!(
        out,
        "MERGE_BLOCKED: protected_paths=releases/v1 [draft] caf\u{00e9}/new.txt"
    );

    git_in(&tmp5.path, &["checkout", "-B", "feat/prot-ren", &trunk5]);
    git_in(
        &tmp5.path,
        &[
            "mv",
            "releases/v1 [draft] caf\u{00e9}/secret.txt",
            "docs/public.txt",
        ],
    );
    git_in(&tmp5.path, &["commit", "-m", "rename out of protected"]);
    let c_pren = find_legacy_case(&cases, "merge_policy_protected_rename_out");
    assert_eq!(c_pren.status_label, "INTENTIONAL_BEHAVIOR_CHANGE");
    let (ec, out, _) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        r5,
        "--ledger-path",
        ".b3/ship/ledger.md",
        "--receipt-path",
        ".b3/ship/head.verify",
    ]);
    assert_eq!(ec, c_pren.legacy_exit_code);
    assert_eq!(
        out,
        "MERGE_BLOCKED: protected_paths=releases/v1 [draft] caf\u{00e9}/secret.txt"
    );

    // 7. Context Cache & Evidence Freshness
    let tmp7 = TempDirGuard::new("leg-f7");
    let base7 = init_git_repo(&tmp7.path);
    let r7 = tmp7.path.to_str().unwrap();

    let c_cc_r = find_legacy_case(&cases, "context_cache_record");
    let (ec, out, _) = run_b3(&[
        "guard",
        "context-cache",
        "--repo-root",
        r7,
        "--action",
        "record",
        "--cache-path",
        ".b3/ship/ctx.cache",
        "--scope-id",
        "T1",
        "--anchor-paths",
        "docs/guide.md",
        "--scope-paths",
        "src/app.txt",
    ]);
    assert_eq!(ec, c_cc_r.legacy_exit_code);
    assert_eq!(
        normalize_dynamic_tokens(out, &[("<HEAD_SHA>", &base7)]),
        c_cc_r.legacy_stdout_normalized
    );

    let c_cc_f = find_legacy_case(&cases, "context_cache_check_fresh");
    let (ec, out, _) = run_b3(&[
        "guard",
        "context-cache",
        "--repo-root",
        r7,
        "--action",
        "check",
        "--cache-path",
        ".b3/ship/ctx.cache",
        "--scope-id",
        "T1",
        "--anchor-paths",
        "docs/guide.md",
        "--scope-paths",
        "src/app.txt",
    ]);
    assert_eq!(ec, c_cc_f.legacy_exit_code);
    assert_eq!(
        normalize_dynamic_tokens(out, &[("<HEAD_SHA>", &base7)]),
        c_cc_f.legacy_stdout_normalized
    );

    let c_ev_w = find_legacy_case(&cases, "evidence_check_write");
    let (ec, out, _) = run_b3(&[
        "guard",
        "evidence-check",
        "--repo-root",
        r7,
        "--write-manifest",
        "--manifest-path",
        ".b3/ship/ev.manifest",
        "--source-paths",
        "docs/guide.md",
    ]);
    assert_eq!(ec, c_ev_w.legacy_exit_code);
    assert_eq!(out, c_ev_w.legacy_stdout_normalized);

    let c_ev_f = find_legacy_case(&cases, "evidence_check_fresh");
    let (ec, out, _) = run_b3(&[
        "guard",
        "evidence-check",
        "--repo-root",
        r7,
        "--manifest-path",
        ".b3/ship/ev.manifest",
    ]);
    assert_eq!(ec, c_ev_f.legacy_exit_code);
    assert_eq!(out, c_ev_f.legacy_stdout_normalized);

    fs::write(tmp7.path.join("docs/guide.md"), "doc v2-stale\n").unwrap();
    let c_cc_s = find_legacy_case(&cases, "context_cache_check_stale");
    let (ec, out, _) = run_b3(&[
        "guard",
        "context-cache",
        "--repo-root",
        r7,
        "--action",
        "check",
        "--cache-path",
        ".b3/ship/ctx.cache",
        "--scope-id",
        "T1",
        "--anchor-paths",
        "docs/guide.md",
        "--scope-paths",
        "src/app.txt",
    ]);
    assert_eq!(ec, c_cc_s.legacy_exit_code);
    assert_eq!(out, c_cc_s.legacy_stdout_normalized);

    let c_ev_s = find_legacy_case(&cases, "evidence_check_stale");
    let (ec, out, _) = run_b3(&[
        "guard",
        "evidence-check",
        "--repo-root",
        r7,
        "--manifest-path",
        ".b3/ship/ev.manifest",
    ]);
    assert_eq!(ec, c_ev_s.legacy_exit_code);
    assert_eq!(out, c_ev_s.legacy_stdout_normalized);

    // 8. PR Verify & In-Process Merge Policy (zero Node.js dependency)
    let tmp8 = TempDirGuard::new("leg-f8");
    let mock_bin = tmp8.path.join("bin");
    let repo8 = tmp8.path.join("repo");
    fs::create_dir_all(&mock_bin).unwrap();
    fs::create_dir_all(repo8.join(".b3")).unwrap();
    init_git_repo(&repo8);
    git_in(
        &repo8,
        &[
            "remote",
            "add",
            "origin",
            "https://github.com/acme/demo.git",
        ],
    );
    fs::write(
        repo8.join(".b3/research-policy.json"),
        "{\"auto_merge\":\"authorized\",\"require_ci\":true,\"require_review\":false}\n",
    )
    .unwrap();
    git_in(&repo8, &["add", "-A"]);
    git_in(&repo8, &["commit", "-m", "policy"]);
    let t8 = git_in(&repo8, &["rev-parse", "HEAD"]);
    git_in(&repo8, &["checkout", "-b", "feat/pr"]);
    fs::write(repo8.join("src/app.txt"), "pr\n").unwrap();
    git_in(&repo8, &["add", "-A"]);
    git_in(&repo8, &["commit", "-m", "pr change"]);
    let h8 = git_in(&repo8, &["rev-parse", "HEAD"]);

    #[cfg(windows)]
    {
        fs::write(mock_bin.join("gh.cmd"), "@echo off\r\necho {}\r\n").unwrap();
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let gh_sh = mock_bin.join("gh");
        fs::write(&gh_sh, "#!/bin/sh\necho '{}'\n").unwrap();
        let mut perms = fs::metadata(&gh_sh).unwrap().permissions();
        perms.set_mode(0o755);
        fs::set_permissions(&gh_sh, perms).unwrap();
    }
    let sep = if cfg!(windows) { ";" } else { ":" };
    let orig_path = std::env::var("PATH").unwrap_or_default();
    let patched_path = format!("{}{sep}{orig_path}", mock_bin.display());
    let c_pv = find_legacy_case(&cases, "pr_verify_zero_node");
    assert_eq!(c_pv.status_label, "INTENTIONAL_BEHAVIOR_CHANGE");
    let (ec, out, _) = run_b3_with_env(
        &[
            "pr",
            "verify",
            "--mode",
            "pre-merge",
            "--repo-root",
            repo8.to_str().unwrap(),
            "--repo",
            "acme/demo",
            "--pr-number",
            "42",
        ],
        Some(&repo8),
        &[("PATH", &patched_path)],
    );
    assert_eq!(ec, 1);
    assert_eq!(out, "GH_VERIFY_ERROR: pr_number_mismatch");

    let c_mpv = find_legacy_case(&cases, "merge_policy_inprocess_pr_verify");
    assert_eq!(c_mpv.status_label, "INTENTIONAL_BEHAVIOR_CHANGE");
    let (ec, out, _) = run_b3_with_env(
        &[
            "guard",
            "merge-policy-check",
            "--repo-root",
            repo8.to_str().unwrap(),
            "--pr-number",
            "42",
            "--repo",
            "acme/demo",
            "--target-branch",
            "main",
            "--base-sha",
            &t8,
            "--head-sha",
            &h8,
        ],
        Some(&repo8),
        &[("PATH", &patched_path)],
    );
    assert_eq!(ec, 1);
    assert_eq!(
        out,
        "MERGE_BLOCKED: github_verification_failed(pr_number_mismatch)"
    );

    // 9. Installer Ownership (cursor, codex, sync --verify-only)
    let b3_home = repo_root();
    let b3_home_str = b3_home.to_str().unwrap();

    for (id, host) in [
        ("install_product_cursor", "cursor"),
        ("install_product_codex", "codex"),
    ] {
        let prod = TempDirGuard::new(&format!("leg-{host}"));
        init_git_repo(&prod.path);
        let c_inst = find_legacy_case(&cases, id);
        let (ec, out, _) = run_b3_with_env(
            &[
                "install",
                "product",
                "--product-root",
                prod.path.to_str().unwrap(),
                "--b3-home",
                b3_home_str,
                "--host",
                host,
            ],
            None,
            &[("B3_SKIP_MODEL_INIT", "1")],
        );
        assert_eq!(ec, c_inst.legacy_exit_code, "install {host}: {out}");
        let norm_out = replace_path_variants(out, &prod.path, "<PROD_ROOT>");
        let norm_out = replace_path_variants(norm_out, &b3_home, "<B3_HOME>");
        assert_eq!(
            norm_out.replace('\\', "/"),
            c_inst.legacy_stdout_normalized.replace('\\', "/"),
            "install {host} output"
        );
        assert!(prod.path.join(".b3/home").is_file());
    }

    let sync_tmp = TempDirGuard::new("leg-sync");
    fs::create_dir_all(sync_tmp.path.join("skills/demo/hello")).unwrap();
    fs::write(
        sync_tmp.path.join("skills/demo/hello/SKILL.md"),
        "---\nname: hello\ndescription: demo\n---\n",
    )
    .unwrap();
    let (sc1, _, _) = run_b3_with_env(
        &[
            "sync",
            "--repo-root",
            sync_tmp.path.to_str().unwrap(),
            "--host",
            "antigravity",
        ],
        None,
        &[("B3_SKIP_MODEL_INIT", "1")],
    );
    assert_eq!(sc1, 0);
    let c_sv = find_legacy_case(&cases, "sync_skills_antigravity_verify_only");
    let (ec, out, _) = run_b3_with_env(
        &[
            "sync",
            "--repo-root",
            sync_tmp.path.to_str().unwrap(),
            "--host",
            "antigravity",
            "--verify-only",
        ],
        None,
        &[("B3_SKIP_MODEL_INIT", "1")],
    );
    assert_eq!(ec, c_sv.legacy_exit_code);
    let norm_sv = replace_path_variants(out, &sync_tmp.path, "<SYNC_ROOT>");
    assert_eq!(
        norm_sv.replace('\\', "/"),
        c_sv.legacy_stdout_normalized.replace('\\', "/")
    );
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
    assert!(out_ctx.contains("warnings          : 0"), "out={out_ctx}");

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
