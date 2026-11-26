//! Fast native Rust behavioral tests for deterministic `b3` core contracts.
//! Replaces duplicated PowerShell/Bash wrapper loops with direct `b3` invocations
//! backed by cached git fixtures.

mod common;

use common::{git_in, init_git_repo, run_b3, TempDirGuard};
use std::fs;
use std::path::Path;

fn commit_file(repo: &Path, rel: &str, content: &str, msg: &str) -> String {
    let p = repo.join(rel);
    if let Some(parent) = p.parent() {
        fs::create_dir_all(parent).unwrap();
    }
    fs::write(&p, content).unwrap();
    git_in(repo, &["add", rel]);
    git_in(repo, &["commit", "-m", msg]);
    git_in(repo, &["rev-parse", "HEAD"])
}

#[test]
fn core_diff_scope_tshirt_tiers_noise_and_risk_signals() {
    let tmp = TempDirGuard::new("diff-scope");
    let repo = tmp.path.join("repo");
    let base = init_git_repo(&repo);
    let r = repo.to_str().unwrap();

    // 1. NOISE_ONLY when only lockfiles change
    commit_file(&repo, "package-lock.json", "{\n  \"lockfileVersion\": 3\n}\n", "lock");
    let (c, out, _) = run_b3(&["guard", "diff-scope", "--repo-root", r, "--base-sha", &base]);
    assert_eq!(c, 0, "{out}");
    assert!(out.contains("size_class=NOISE_ONLY"), "{out}");

    // 2. XS + HIGH risk signal on auth path
    commit_file(&repo, "src/auth/login.ts", "export const login = () => true;\n", "auth");
    let (c, out, _) = run_b3(&["guard", "diff-scope", "--repo-root", r, "--base-sha", &base]);
    assert_eq!(c, 0, "{out}");
    assert!(out.contains("size_class=XS"), "{out}");
    assert!(out.contains("risk_level=CRITICAL"), "{out}");
    assert!(out.contains("b3-security-reviewer"), "{out}");

    // 3. M tier by LOC (>300 lines)
    let big_body: String = (0..350).map(|i| format!("export const v{i} = {i};\n")).collect();
    commit_file(&repo, "src/module.ts", &big_body, "big");
    let (c, out, _) = run_b3(&["guard", "diff-scope", "--repo-root", r, "--base-sha", &base]);
    assert_eq!(c, 0, "{out}");
    assert!(out.contains("size_class=M") || out.contains("size_class=L"), "{out}");
}

#[test]
fn core_review_inventory_xxl_and_unit_cap() {
    let tmp = TempDirGuard::new("rev-inv");
    let repo = tmp.path.join("repo");
    let base = init_git_repo(&repo);
    let r = repo.to_str().unwrap();

    // Generate 25,000+ LOC across 120 files across 4 areas to trigger XXL + <=4 unit cap
    let chunk: String = (0..220).map(|i| format!("pub fn f{i}() -> i32 {{ {i} }}\n")).collect();
    for i in 0..120 {
        let area = match i % 4 {
            0 => "api",
            1 => "core",
            2 => "data",
            _ => "ui",
        };
        let p = repo.join(format!("src/{area}/m{i:03}.rs"));
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(&p, &chunk).unwrap();
    }
    git_in(&repo, &["add", "."]);
    git_in(&repo, &["commit", "-m", "xxl"]);

    let (c, out, _) = run_b3(&[
        "guard",
        "review-inventory",
        "--repo-root",
        r,
        "--base-sha",
        &base,
        "--max-concurrency",
        "8",
    ]);
    assert_eq!(c, 0, "{out}");
    assert!(out.contains("size_class=XXL"), "{out}");
    assert!(out.contains("split_recommended=true"), "{out}");
    assert!(out.contains("max_concurrency=4"), "{out}");
    let unit_count = out.lines().filter(|l| l.starts_with("unit|")).count();
    assert!(unit_count >= 4, "expected >=4 units for XXL, got {unit_count}");
}

#[test]
fn core_review_ledger_fail_closed_gates_and_tamper_detection() {
    let tmp = TempDirGuard::new("rev-ledger");
    let repo = tmp.path.join("repo");
    let base = init_git_repo(&repo);
    let head = commit_file(&repo, "src/auth/token.rs", "pub fn verify() {}\n", "auth");
    let r = repo.to_str().unwrap();
    let ledger = repo.join(".b3/ship/runs/t1/review-ledger.md");
    let lp = ledger.to_str().unwrap();

    // Init ledger -> defaults review_independence=UNKNOWN
    let (c, out, _) = run_b3(&[
        "guard",
        "review-ledger",
        "--action",
        "init",
        "--repo-root",
        r,
        "--ledger-path",
        lp,
        "--base-sha",
        &base,
    ]);
    assert_eq!(c, 0, "{out}");
    let raw = fs::read_to_string(&ledger).unwrap();
    assert!(raw.contains("review_independence=UNKNOWN"), "{raw}");

    // Check fails closed on UNKNOWN / incomplete units
    let (c, out, _) = run_b3(&[
        "guard",
        "review-ledger",
        "--action",
        "check",
        "--repo-root",
        r,
        "--ledger-path",
        lp,
        "--base-sha",
        &base,
    ]);
    assert_eq!(c, 2, "{out}");

    // Self-waiver on CRITICAL specialist is rejected
    let (c, out, _) = run_b3(&[
        "guard",
        "review-ledger",
        "--action",
        "update",
        "--repo-root",
        r,
        "--ledger-path",
        lp,
        "--unit-id",
        "U01",
        "--status",
        "PASS",
        "--specialists",
        "WAIVER:self-waived",
        "--review-independence",
        "SINGLE_AGENT_LIMIT",
        "--passes-used",
        "1",
    ]);
    assert!(c != 0, "expected waiver/single-agent rejection, got {c}: {out}");
    let _ = head;
}

#[test]
fn core_check_wave_rw_protected_and_partition() {
    let tmp = TempDirGuard::new("wave");
    let repo = tmp.path.join("repo");
    let base = init_git_repo(&repo);
    let r = repo.to_str().unwrap();

    // Disjoint writes + shared reader
    let (c, out, _) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r,
        "--expected-base-sha",
        &base,
        "--wave-specs",
        "T001=src/a.rs;T002=src/b.rs;T003=none",
    ]);
    assert_eq!(c, 0, "{out}");
    assert!(out.contains("WAVE_OK"), "{out}");

    // Read-write conflict triggers WAVE_CONFLICT (exit 2)
    let (c, out, _) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r,
        "--wave-specs",
        "T001=src/a.rs;T002=src/b.rs",
        "--wave-reads",
        "T002=src/a.rs",
    ]);
    assert_eq!(c, 2, "{out}");
    assert!(out.contains("WAVE_CONFLICT"), "{out}");

    // ProtectedPaths conflict triggers exit 1 (WAVE_FAIL)
    let (c, out, _) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r,
        "--wave-specs",
        "T001=src/a.rs",
        "--protected-paths",
        "src/a.rs",
    ]);
    assert_eq!(c, 1, "{out}");
    assert!(out.contains("WAVE_FAIL"), "{out}");

    // Partition respects MaxConcurrency
    let (c, out, _) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r,
        "--wave-specs",
        "T001=a.rs;T002=b.rs;T003=c.rs;T004=d.rs",
        "--partition",
        "--max-concurrency",
        "2",
    ]);
    assert_eq!(c, 0, "{out}");
    assert!(out.contains("WAVE_PARTITIONED"), "{out}");
}

#[test]
fn core_mechanical_check_dirty_digests_and_context_cache() {
    let tmp = TempDirGuard::new("mech-ctx");
    let repo = tmp.path.join("repo");
    let base = init_git_repo(&repo);
    let r = repo.to_str().unwrap();

    // DirtyDigests tamper detection
    fs::write(repo.join("src/app.txt"), "tampered\n").unwrap();
    let (c, out, _) = run_b3(&[
        "guard",
        "mechanical-check",
        "--repo-root",
        r,
        "--base-sha",
        &base,
        "--allowed-paths",
        "docs/guide.md",
        "--dirty-digests",
        "src/app.txt=0000000000000000000000000000000000000000000000000000000000000000",
    ]);
    assert_eq!(c, 2, "{out}");
    assert!(out.contains("dirty_tamper"), "{out}");

    // Context-cache record -> fresh -> tamper fail-closed
    fs::write(repo.join("src/app.txt"), "v1\n").unwrap();
    let summary = repo.join(".b3/ship/runs/t1/summary.md");
    fs::create_dir_all(summary.parent().unwrap()).unwrap();
    fs::write(&summary, "# Summary\n").unwrap();
    let cache = repo.join(".b3/ship/runs/t1/context-cache.txt");
    let cp = ".b3/ship/runs/t1/context-cache.txt";
    let sp = ".b3/ship/runs/t1/summary.md";

    let (c, out, _) = run_b3(&[
        "guard",
        "context-cache",
        "--action",
        "record",
        "--repo-root",
        r,
        "--cache-path",
        cp,
        "--scope-id",
        "T001",
        "--anchor-paths",
        "src/app.txt",
        "--scope-paths",
        "docs/guide.md",
        "--summary-ref",
        sp,
    ]);
    assert_eq!(c, 0, "{out}");
    assert!(out.contains("CONTEXT_RECORDED"), "{out}");

    let (c, out, _) = run_b3(&[
        "guard",
        "context-cache",
        "--action",
        "check",
        "--repo-root",
        r,
        "--cache-path",
        cp,
        "--scope-id",
        "T001",
        "--anchor-paths",
        "src/app.txt",
        "--scope-paths",
        "docs/guide.md",
        "--summary-ref",
        sp,
    ]);
    assert_eq!(c, 0, "{out}");
    assert!(out.contains("CONTEXT_FRESH"), "{out}");

    // Tamper cache file -> fail closed (exit 1)
    let mut raw = fs::read_to_string(&cache).unwrap();
    raw.push_str("tamper=1\n");
    fs::write(&cache, raw).unwrap();
    let (c, _, _) = run_b3(&[
        "guard",
        "context-cache",
        "--action",
        "check",
        "--repo-root",
        r,
        "--cache-path",
        cp,
        "--scope-id",
        "T001",
    ]);
    assert_eq!(c, 1);
}

#[test]
fn core_evidence_check_containment_and_staleness() {
    let tmp = TempDirGuard::new("evidence");
    let repo = tmp.path.join("repo");
    init_git_repo(&repo);
    let r = repo.to_str().unwrap();
    let manifest = repo.join(".b3/research-ship/runs/r1/evidence.manifest");
    fs::create_dir_all(manifest.parent().unwrap()).unwrap();
    let mp = ".b3/research-ship/runs/r1/evidence.manifest";

    let (c, out, _) = run_b3(&[
        "guard",
        "evidence-check",
        "--repo-root",
        r,
        "--manifest-path",
        mp,
        "--source-paths",
        "src/app.txt,docs/guide.md",
        "--write-manifest",
    ]);
    assert_eq!(c, 0, "{out}");
    assert!(out.contains("EVIDENCE_WRITTEN"), "{out}");

    let (c, out, _) = run_b3(&[
        "guard",
        "evidence-check",
        "--repo-root",
        r,
        "--manifest-path",
        mp,
    ]);
    assert_eq!(c, 0, "{out}");
    assert!(out.contains("EVIDENCE_FRESH"), "{out}");

    // Modify source -> EVIDENCE_STALE (exit 2)
    fs::write(repo.join("src/app.txt"), "v2\n").unwrap();
    let (c, out, _) = run_b3(&[
        "guard",
        "evidence-check",
        "--repo-root",
        r,
        "--manifest-path",
        mp,
    ]);
    assert_eq!(c, 2, "{out}");
    assert!(out.contains("EVIDENCE_STALE"), "{out}");

    // Path traversal rejected (exit 1)
    let (c, _, _) = run_b3(&[
        "guard",
        "evidence-check",
        "--repo-root",
        r,
        "--manifest-path",
        mp,
        "--source-paths",
        "../outside.txt",
        "--write-manifest",
    ]);
    assert_eq!(c, 1);
}
