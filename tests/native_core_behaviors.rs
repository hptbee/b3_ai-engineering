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
    commit_file(
        &repo,
        "package-lock.json",
        "{\n  \"lockfileVersion\": 3\n}\n",
        "lock",
    );
    let (c, out, _) = run_b3(&["guard", "diff-scope", "--repo-root", r, "--base-sha", &base]);
    assert_eq!(c, 0, "{out}");
    assert!(out.contains("size_class=NOISE_ONLY"), "{out}");

    // 2. XS + HIGH risk signal on auth path
    commit_file(
        &repo,
        "src/auth/login.ts",
        "export const login = () => true;\n",
        "auth",
    );
    let (c, out, _) = run_b3(&["guard", "diff-scope", "--repo-root", r, "--base-sha", &base]);
    assert_eq!(c, 0, "{out}");
    assert!(out.contains("size_class=XS"), "{out}");
    assert!(out.contains("risk_level=CRITICAL"), "{out}");
    assert!(out.contains("b3-security-reviewer"), "{out}");

    // 3. M tier by LOC (>300 lines)
    let big_body: String = (0..350)
        .map(|i| format!("export const v{i} = {i};\n"))
        .collect();
    commit_file(&repo, "src/module.ts", &big_body, "big");
    let (c, out, _) = run_b3(&["guard", "diff-scope", "--repo-root", r, "--base-sha", &base]);
    assert_eq!(c, 0, "{out}");
    assert!(
        out.contains("size_class=M") || out.contains("size_class=L"),
        "{out}"
    );
}

#[test]
fn core_review_inventory_xxl_and_unit_cap() {
    let tmp = TempDirGuard::new("rev-inv");
    let repo = tmp.path.join("repo");
    let base = init_git_repo(&repo);
    let r = repo.to_str().unwrap();

    // Generate 25,000+ LOC across 120 files across 4 areas to trigger XXL + <=4 unit cap
    let chunk: String = (0..220)
        .map(|i| format!("pub fn f{i}() -> i32 {{ {i} }}\n"))
        .collect();
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
    assert!(out.contains("max_concurrency=8"), "{out}");
    let unit_count = out.lines().filter(|l| l.starts_with("unit|")).count();
    assert!(
        unit_count >= 4,
        "expected >=4 units for XXL, got {unit_count}"
    );
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

    // Self-waiver on CRITICAL specialist is accepted on update but blocked on check (exit 2)
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
        "REVIEWED",
        "--specialists",
        "WAIVER:self-waived",
        "--review-independence",
        "INDEPENDENT",
        "--passes-used",
        "1",
    ]);
    assert_eq!(c, 0, "{out}");
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
    assert_eq!(c, 2, "expected self-waiver block on check, got {c}: {out}");
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

#[test]
fn core_context_cache_graph_index_and_path_traversal() {
    let tmp = TempDirGuard::new("ctx-r3");
    let repo = tmp.path.join("repo");
    let base = init_git_repo(&repo);
    let r = repo.to_str().unwrap();

    let summary = repo.join(".b3/ship/runs/t2/summary.md");
    fs::create_dir_all(summary.parent().unwrap()).unwrap();
    fs::write(&summary, "# Summary v1\n").unwrap();
    let cp = ".b3/ship/runs/t2/context-cache.txt";
    let sp = ".b3/ship/runs/t2/summary.md";

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
        "T002",
        "--anchor-paths",
        "src/app.txt",
        "--scope-paths",
        "docs/guide.md",
        "--graph-index-sha",
        &base,
        "--summary-ref",
        sp,
    ]);
    assert_eq!(c, 0, "{out}");

    let head2 = commit_file(&repo, "docs/guide.md", "doc v2\n", "c2");

    // Mismatched graph-index-sha -> exit 2 (CONTEXT_STALE: graph_index_mismatch)
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
        "T002",
        "--graph-index-sha",
        &head2,
    ]);
    assert_eq!(c, 2, "{out}");
    assert!(out.contains("graph_index_mismatch"), "{out}");

    // CRLF tamper, empty cache tamper, and MERGE_HEAD -> fail closed (exit 1)
    let cache_full = repo.join(cp);
    let raw = fs::read_to_string(&cache_full).unwrap();
    fs::write(&cache_full, raw.replace('\n', "\r\n")).unwrap();
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
        "T002",
    ]);
    assert_eq!(c, 1);
    fs::write(&cache_full, "").unwrap();
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
        "T002",
    ]);
    assert_eq!(c, 1);

    // Anchor change -> CONTEXT_STALE (exit 2)
    let cp2 = ".b3/ship/runs/t2/context-cache-2.txt";
    let (c, _, _) = run_b3(&[
        "guard",
        "context-cache",
        "--action",
        "record",
        "--repo-root",
        r,
        "--cache-path",
        cp2,
        "--scope-id",
        "T002",
        "--anchor-paths",
        "src/app.txt",
        "--summary-ref",
        sp,
    ]);
    assert_eq!(c, 0);
    fs::write(repo.join("src/app.txt"), "v2\n").unwrap();
    let (c, out, _) = run_b3(&[
        "guard",
        "context-cache",
        "--action",
        "check",
        "--repo-root",
        r,
        "--cache-path",
        cp2,
        "--scope-id",
        "T002",
        "--anchor-paths",
        "src/app.txt",
        "--summary-ref",
        sp,
    ]);
    assert_eq!(c, 2, "{out}");
    assert!(out.contains("CONTEXT_STALE"), "{out}");

    // Path traversal rejected (exit 1)
    let (c, _, _) = run_b3(&[
        "guard",
        "context-cache",
        "--action",
        "record",
        "--repo-root",
        r,
        "--cache-path",
        "../escape.txt",
        "--scope-id",
        "T002",
    ]);
    assert_eq!(c, 1);
}

#[test]
fn core_review_ledger_monotonic_passes_and_init_overwrite_guard() {
    let tmp = TempDirGuard::new("ledger-r3");
    let repo = tmp.path.join("repo");
    let base = init_git_repo(&repo);
    commit_file(&repo, "src/lib.rs", "pub fn a() -> i32 { 1 }\n", "c1");
    let r = repo.to_str().unwrap();
    let ledger = repo.join(".b3/ship/runs/t2/review-ledger.md");
    let lp = ledger.to_str().unwrap();

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

    // Update U01 with passes_used=2, then attempt init overwrite without --force and bypass with passes_used=1 -> exit 1
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
        "REVIEWED",
        "--review-independence",
        "INDEPENDENT",
        "--passes-used",
        "2",
    ]);
    assert_eq!(c, 0, "{out}");

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
    assert_eq!(c, 1, "{out}");

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
        "REVIEWED",
        "--passes-used",
        "1",
    ]);
    assert_eq!(c, 1, "{out}");
    assert!(out.contains("passes_used cannot be reduced"), "{out}");

    // Advancing head_sha resets review_independence=INDEPENDENT -> UNKNOWN on check (exit 2)
    commit_file(&repo, "src/lib.rs", "pub fn a() -> i32 { 2 }\n", "c2");
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
}

#[test]
fn core_mechanical_worker_changes_symbol_check_and_evidence_tamper() {
    let tmp = TempDirGuard::new("mech-sym-ev");
    let repo = tmp.path.join("repo");
    let base = init_git_repo(&repo);
    commit_file(
        &repo,
        "src/mod.rs",
        "pub fn exported_api() -> i32 { 1 }\nfn internal_dead() -> i32 { 2 }\n",
        "add syms",
    );
    commit_file(
        &repo,
        "src/caller.rs",
        "pub fn call() -> i32 { exported_api() }\n",
        "add caller",
    );
    let r = repo.to_str().unwrap();

    // Remove exported_api while caller.rs references it -> symbol-check flags dangling_refs (exit 2)
    let base2 = git_in(&repo, &["rev-parse", "HEAD"]);
    commit_file(
        &repo,
        "src/mod.rs",
        "fn internal_dead() -> i32 { 2 }\n",
        "drop api",
    );
    let (c, out, _) = run_b3(&[
        "guard",
        "symbol-check",
        "--repo-root",
        r,
        "--base-sha",
        &base2,
    ]);
    assert_eq!(c, 2, "{out}");
    assert!(out.contains("exported_removed"), "{out}");
    assert!(out.contains("dangling_refs"), "{out}");

    // WorkerChanges attribution violation -> exit 2
    let (c, out, _) = run_b3(&[
        "guard",
        "mechanical-check",
        "--repo-root",
        r,
        "--base-sha",
        &base,
        "--allowed-paths",
        "src/mod.rs",
        "--wave-specs",
        "T001=docs/guide.md",
        "--worker-changes",
        "T001=src/mod.rs",
    ]);
    assert_eq!(c, 2, "{out}");
    assert!(out.contains("VIOLATION"), "{out}");

    // Evidence manifest tamper -> fail closed (exit 1)
    let manifest = repo.join(".b3/research-ship/runs/r2/evidence.manifest");
    fs::create_dir_all(manifest.parent().unwrap()).unwrap();
    let mp = ".b3/research-ship/runs/r2/evidence.manifest";
    let (c, out, _) = run_b3(&[
        "guard",
        "evidence-check",
        "--repo-root",
        r,
        "--manifest-path",
        mp,
        "--source-paths",
        "src/app.txt",
        "--write-manifest",
    ]);
    assert_eq!(c, 0, "{out}");
    fs::write(&manifest, "corrupt-manifest\n").unwrap();
    let (c, _, _) = run_b3(&[
        "guard",
        "evidence-check",
        "--repo-root",
        r,
        "--manifest-path",
        mp,
    ]);
    assert_eq!(c, 1);
}

#[test]
fn core_r006_junction_symlink_guards_and_verify_containment() {
    let tmp = TempDirGuard::new("r006");
    let repo = tmp.path.join("repo");
    let head = init_git_repo(&repo);
    let r = repo.to_str().unwrap();

    let decoy = tmp.path.join("decoy");
    fs::create_dir_all(&decoy).unwrap();
    fs::write(decoy.join("secret.txt"), "keep\n").unwrap();

    // 1. check-worktree rejects junction/symlink worktree (exit 2)
    let linked_wt = tmp.path.join("linked-wt");
    common::create_dir_link(&linked_wt, &repo);
    let (c, _, _) = run_b3(&[
        "guard",
        "check-worktree",
        "--repo-root",
        linked_wt.to_str().unwrap(),
        "--expected-root",
        r,
        "--expected-base-sha",
        &head,
    ]);
    assert_ne!(c, 0);

    // 2. verify-run rejects junction/symlink receipt parent & R016 traversal containment
    let b3_link = repo.join(".b3/ship/runs/junc");
    common::create_dir_link(&b3_link, &decoy);
    let (c, _, _) = run_b3(&[
        "guard",
        "verify-run",
        "--repo-root",
        r,
        "--task-id",
        "T001",
        "--verify-cmd",
        "echo ok",
        "--receipt-path",
        ".b3/ship/runs/junc/r.verify",
    ]);
    assert_eq!(c, 1);

    let (c, _, _) = run_b3(&[
        "guard",
        "verify-run",
        "--repo-root",
        r,
        "--task-id",
        "T001",
        "--verify-cmd",
        "echo ok",
        "--receipt-path",
        "../outside.verify",
    ]);
    assert_eq!(c, 1);

    // 3. context-cache & evidence-check reject junction path
    let (c, _, _) = run_b3(&[
        "guard",
        "context-cache",
        "--action",
        "record",
        "--repo-root",
        r,
        "--cache-path",
        ".b3/ship/runs/junc/cache.txt",
        "--scope-id",
        "T001",
    ]);
    assert_eq!(c, 1);

    let (c, _, _) = run_b3(&[
        "guard",
        "evidence-check",
        "--repo-root",
        r,
        "--manifest-path",
        ".b3/ship/runs/junc/ev.manifest",
        "--source-paths",
        "src/app.txt",
        "--write-manifest",
    ]);
    assert_eq!(c, 1);
    assert!(decoy.join("secret.txt").exists());
}

#[test]
fn core_precommit_adversarial_and_malformed_policy_guards() {
    let tmp = TempDirGuard::new("precommit-adv");
    let repo = tmp.path.join("repo");
    init_git_repo(&repo);
    let r = repo.to_str().unwrap();

    // 1. Secret .env staging rejected when not exact-declared
    fs::write(repo.join(".env"), "SECRET=123\n").unwrap();
    git_in(&repo, &["add", "-f", ".env"]);
    let (c, _, _) = run_b3(&[
        "guard",
        "precommit",
        "--repo-root",
        r,
        "--allowed-paths",
        "src/app.txt",
    ]);
    assert_eq!(c, 1);
    git_in(&repo, &["reset", "-q", "HEAD", ".env"]);
    fs::remove_file(repo.join(".env")).unwrap();

    // 2. Checkpoint .b3/ship/ staging rejected
    fs::create_dir_all(repo.join(".b3/ship")).unwrap();
    fs::write(repo.join(".b3/ship/progress.md"), "cp\n").unwrap();
    git_in(&repo, &["add", "-f", ".b3/ship/progress.md"]);
    let (c, _, _) = run_b3(&[
        "guard",
        "precommit",
        "--repo-root",
        r,
        "--allowed-paths",
        ".b3/ship/progress.md",
    ]);
    assert_eq!(c, 1);
    git_in(&repo, &["reset", "-q", "HEAD", ".b3/ship/progress.md"]);

    // 3. Partial-staged R006: staged src/app.txt + unstaged edit in src/app.txt with receipt -> fail
    fs::write(repo.join("src/app.txt"), "v2\n").unwrap();
    let (c, _, _) = run_b3(&[
        "guard",
        "verify-run",
        "--repo-root",
        r,
        "--task-id",
        "T001",
        "--verify-cmd",
        "echo ok",
        "--receipt-path",
        ".b3/ship/runs/t1/T001.verify",
        "--relevant-paths",
        "src/app.txt",
    ]);
    assert_eq!(c, 0);
    git_in(&repo, &["add", "src/app.txt"]);
    fs::write(repo.join("src/app.txt"), "v3-unstaged\n").unwrap();
    let (c, _, _) = run_b3(&[
        "guard",
        "precommit",
        "--repo-root",
        r,
        "--allowed-paths",
        "src/app.txt",
        "--require-verify-receipt",
        ".b3/ship/runs/t1/T001.verify",
    ]);
    assert_eq!(c, 1);
    git_in(&repo, &["reset", "-q", "--hard", "HEAD"]);

    // 4. Malformed .b3/research-policy.json on trunk -> merge-policy-check fails closed (exit 1)
    commit_file(&repo, ".b3/research-policy.json", "{bad json", "bad policy");
    let (c, out, _) = run_b3(&[
        "guard",
        "merge-policy-check",
        "--repo-root",
        r,
        "--authority-ref",
        "main",
    ]);
    assert_eq!(c, 1, "{out}");
}

#[test]
fn core_review_inventory_subdivides_oversized_test_only_directory() {
    let tmp = TempDirGuard::new("rev-inv-tests-only");
    let repo = tmp.path.join("repo");
    let base = init_git_repo(&repo);
    let r = repo.to_str().unwrap();

    let body_2k: String = (0..2000)
        .map(|i| format!("pub fn case_{i}() -> i32 {{ {i} }}\n"))
        .collect();
    for suite in ["alpha_suite.rs", "beta_suite.rs", "gamma_suite.rs"] {
        let p = repo.join(format!("tests/{suite}"));
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(&p, &body_2k).unwrap();
    }
    git_in(&repo, &["add", "."]);
    git_in(&repo, &["commit", "-m", "add three 2k test suites"]);

    let (c, out, err) = run_b3(&[
        "guard",
        "review-inventory",
        "--repo-root",
        r,
        "--base-sha",
        &base,
    ]);
    assert_eq!(c, 0, "expected partitioned inventory exit 0: {out}\n{err}");
    assert!(out.contains("size_class=XXL"), "{out}");
    let units: Vec<&str> = out.lines().filter(|l| l.starts_with("unit|")).collect();
    assert!(units.len() >= 2, "expected >= 2 subdivided units: {out}");
    for ul in &units {
        let cols: Vec<&str> = ul.split('|').collect();
        let lines_cnt: usize = cols[4].parse().expect("unit lines count");
        assert!(lines_cnt <= 5000, "oversized unit emitted: {ul}");
    }

    let body_5100: String = (0..5100)
        .map(|i| format!("pub fn giant_{i}() -> i32 {{ {i} }}\n"))
        .collect();
    fs::write(repo.join("tests/giant_suite.rs"), &body_5100).unwrap();
    let (gc, gout, gerr) = run_b3(&[
        "guard",
        "review-inventory",
        "--repo-root",
        r,
        "--base-sha",
        &base,
    ]);
    assert_eq!(
        gc, 2,
        "single >5000L test file must fail exit 2: {gout}\n{gerr}"
    );
    assert!(
        gerr.contains("PARTITION_INCOMPLETE:") || gout.contains("PARTITION_INCOMPLETE:"),
        "{gout}\n{gerr}"
    );
}

#[test]
fn core_symbol_check_batch_preserves_leading_space_and_special_filenames() {
    let tmp = TempDirGuard::new("sym-batch-special-names");
    let repo = tmp.path.join("repo");
    init_git_repo(&repo);
    let r = repo.to_str().unwrap();

    commit_file(
        &repo,
        "src/api.rs",
        "pub fn alpha_removed() {}\npub fn beta_removed() {}\n",
        "add api",
    );
    commit_file(
        &repo,
        " caller.rs",
        "fn call_a() { alpha_removed(); }\n",
        "add leading-space caller",
    );
    let base_head = commit_file(
        &repo,
        "src/[id]/special caller.rs",
        "fn call_b() { beta_removed(); }\n",
        "add special caller",
    );

    fs::write(
        repo.join("src/api.rs"),
        "fn helper_used_fn() {}\nfn orphan_only_fn() {}\n",
    )
    .unwrap();
    fs::write(
        repo.join(" caller.rs"),
        "fn call_a() { alpha_removed(); helper_used_fn(); }\n",
    )
    .unwrap();

    let (c1, out1, err1) = run_b3(&[
        "guard",
        "symbol-check",
        "--repo-root",
        r,
        "--base-sha",
        &base_head,
    ]);
    assert_eq!(c1, 2, "working-tree symbol-check failed: {out1}\n{err1}");
    assert!(out1.contains("alpha_removed(1f)"), "{out1}");
    assert!(out1.contains("beta_removed(1f)"), "{out1}");
    assert!(out1.contains("src/api.rs:orphan_only_fn"), "{out1}");
    assert!(!out1.contains("helper_used_fn"), "{out1}");

    git_in(&repo, &["add", "."]);
    git_in(&repo, &["commit", "-m", "remove exports and add privs"]);

    let (c2, out2, err2) = run_b3(&[
        "guard",
        "symbol-check",
        "--repo-root",
        r,
        "--base-sha",
        &base_head,
        "--target-ref",
        "HEAD",
    ]);
    assert_eq!(c2, 2, "commit-ref symbol-check failed: {out2}\n{err2}");
    assert!(out2.contains("alpha_removed(1f)"), "{out2}");
    assert!(out2.contains("beta_removed(1f)"), "{out2}");
    assert!(out2.contains("src/api.rs:orphan_only_fn"), "{out2}");
    assert!(!out2.contains("helper_used_fn"), "{out2}");
}

#[test]
fn core_precommit_consolidated_expected_cmd_relevant_paths_and_manifest_invalidation() {
    let tmp = TempDirGuard::new("precommit-consolidated");
    let repo = tmp.path.join("repo");
    init_git_repo(&repo);
    let r = repo.to_str().unwrap();

    commit_file(
        &repo,
        "Cargo.toml",
        "[package]\nname = \"demo\"\nversion = \"0.1.0\"\n",
        "add cargo manifest",
    );
    commit_file(
        &repo,
        "src/app.rs",
        "pub fn run() -> i32 { 1 }\n",
        "add app",
    );
    commit_file(
        &repo,
        "tests/shared.rs",
        "pub fn shared_assert() {}\n",
        "add shared test",
    );

    fs::write(repo.join("src/app.rs"), "pub fn run() -> i32 { 2 }\n").unwrap();
    git_in(&repo, &["add", "src/app.rs"]);

    let receipt_rel = ".b3/ship/evidence/T1.verify";
    let (vc, vout, verr) = run_b3(&[
        "guard",
        "verify-run",
        "--repo-root",
        r,
        "--task-id",
        "T1",
        "--relevant-paths",
        "src/app.rs,tests/shared.rs",
        "--receipt-path",
        receipt_rel,
        "--verify-cmd",
        "echo ok",
    ]);
    assert_eq!(vc, 0, "verify-run failed: {vout}\n{verr}");

    // Flags without --require-verify-receipt fail closed
    let (nf_c, nf_out, _) = run_b3(&[
        "guard",
        "precommit",
        "--repo-root",
        r,
        "--allowed-paths",
        "src/app.rs",
        "--expected-cmd",
        "echo ok",
    ]);
    assert_eq!(nf_c, 1);
    assert!(
        nf_out.contains("require --require-verify-receipt"),
        "{nf_out}"
    );

    // Wrong expected-cmd rejected cleanly
    let (wc, w_out, _) = run_b3(&[
        "guard",
        "precommit",
        "--repo-root",
        r,
        "--allowed-paths",
        "src/app.rs",
        "--require-verify-receipt",
        receipt_rel,
        "--expected-cmd",
        "echo wrong",
    ]);
    assert_eq!(wc, 1);
    assert!(w_out.contains("VERIFY_MISMATCH"), "{w_out}");

    // Uncovered required non-staged path rejected cleanly
    let (rc, r_out, _) = run_b3(&[
        "guard",
        "precommit",
        "--repo-root",
        r,
        "--allowed-paths",
        "src/app.rs",
        "--require-verify-receipt",
        receipt_rel,
        "--relevant-paths",
        "src/app.rs,tests/other.rs",
    ]);
    assert_eq!(rc, 1);
    assert!(r_out.contains("VERIFY_SCOPE_MISMATCH"), "{r_out}");

    // Valid consolidated precommit passes (without separate verify-check)
    let (okc, okout, okerr) = run_b3(&[
        "guard",
        "precommit",
        "--repo-root",
        r,
        "--allowed-paths",
        "src/app.rs",
        "--require-verify-receipt",
        receipt_rel,
        "--expected-cmd",
        "echo ok",
        "--relevant-paths",
        "src/app.rs,tests/shared.rs",
    ]);
    assert_eq!(okc, 0, "consolidated precommit failed: {okout}\n{okerr}");

    // Modifying Cargo.toml invalidates scoped receipt in both verify-check and precommit
    fs::write(
        repo.join("Cargo.toml"),
        "[package]\nname = \"demo\"\nversion = \"0.2.0\"\n",
    )
    .unwrap();
    let (vsc, vs_out, _) = run_b3(&[
        "guard",
        "verify-check",
        "--repo-root",
        r,
        "--receipt-path",
        receipt_rel,
        "--expected-cmd",
        "echo ok",
    ]);
    assert_eq!(vsc, 2);
    assert!(vs_out.contains("VERIFY_STALE"), "{vs_out}");

    let (psc, ps_out, _) = run_b3(&[
        "guard",
        "precommit",
        "--repo-root",
        r,
        "--allowed-paths",
        "src/app.rs",
        "--require-verify-receipt",
        receipt_rel,
        "--expected-cmd",
        "echo ok",
    ]);
    assert_eq!(psc, 1);
    assert!(ps_out.contains("VERIFY_STALE"), "{ps_out}");

    // Untracked nested manifest creation also invalidates scoped receipt via ls-files pathspecs
    git_in(&repo, &["add", "Cargo.toml"]);
    let (vc2, _, verr2) = run_b3(&[
        "guard",
        "verify-run",
        "--repo-root",
        r,
        "--task-id",
        "T2",
        "--relevant-paths",
        "src/app.rs,tests/shared.rs",
        "--receipt-path",
        receipt_rel,
        "--verify-cmd",
        "echo ok",
    ]);
    assert_eq!(vc2, 0, "re-verify failed: {verr2}");
    fs::create_dir_all(repo.join("packages/web")).unwrap();
    fs::write(
        repo.join("packages/web/package.json"),
        "{\"name\":\"web\",\"version\":\"1.0.0\"}\n",
    )
    .unwrap();
    let (u_vc, u_out, _) = run_b3(&[
        "guard",
        "verify-check",
        "--repo-root",
        r,
        "--receipt-path",
        receipt_rel,
        "--expected-cmd",
        "echo ok",
    ]);
    assert_eq!(u_vc, 2);
    assert!(u_out.contains("VERIFY_STALE"), "{u_out}");
}

#[test]
fn core_mechanical_and_symbol_advisory_vs_confirmed_blockers() {
    let tmp = TempDirGuard::new("advisory-vs-blocker");
    let repo = tmp.path.join("repo");
    init_git_repo(&repo);
    let r = repo.to_str().unwrap();

    let base = commit_file(
        &repo,
        "src/mod_x.rs",
        "pub fn exported_removed_sym() -> i32 { 1 }\npub fn kept() -> i32 { 2 }\n",
        "seed",
    );
    commit_file(
        &repo,
        "src/caller.rs",
        "pub fn use_it() -> i32 { exported_removed_sym() }\n",
        "caller",
    );
    let base2 = git_in(&repo, &["rev-parse", "HEAD"]);

    // 1. Advisory-only signals (eslint-disable, @ts-ignore, empty TODO) -> exit 0 MECHANICAL_ADVISORY
    fs::write(
        repo.join("src/adv.ts"),
        "// eslint-disable-next-line\n// @ts-ignore\n// TODO:\nexport const ok = 1;\n",
    )
    .unwrap();
    let (mac, maout, maerr) = run_b3(&[
        "guard",
        "mechanical-check",
        "--repo-root",
        r,
        "--base-sha",
        &base2,
        "--allowed-paths",
        "src/adv.ts",
    ]);
    assert_eq!(mac, 0, "advisory-only should exit 0: {maout}\n{maerr}");
    assert!(maout.contains("MECHANICAL_ADVISORY"), "{maout}");
    assert!(maout.contains("advisory_hits="), "{maout}");
    assert!(maout.contains("eslint-disable"), "{maout}");

    // 2. Confirmed blocker (debugger / .only() alongside advisory -> exit 2 MECHANICAL_FINDINGS
    fs::write(
        repo.join("src/adv.ts"),
        "// @ts-ignore\ndebugger;\nexport const ok = 1;\n",
    )
    .unwrap();
    let (mbc, mbout, _) = run_b3(&[
        "guard",
        "mechanical-check",
        "--repo-root",
        r,
        "--base-sha",
        &base2,
        "--allowed-paths",
        "src/adv.ts",
    ]);
    assert_eq!(mbc, 2, "{mbout}");
    assert!(mbout.contains("MECHANICAL_FINDINGS"), "{mbout}");
    assert!(mbout.contains("debugger"), "{mbout}");
    fs::remove_file(repo.join("src/adv.ts")).unwrap();

    // 3. symbol-check: orphan_internal-only -> exit 0 SYMBOL_ADVISORY; dangling_refs -> exit 2 SYMBOL_FINDINGS
    fs::write(
        repo.join("src/mod_x.rs"),
        "pub fn exported_removed_sym() -> i32 { 1 }\npub fn kept() -> i32 { 2 }\nfn unreferenced_priv() -> i32 { 3 }\n",
    )
    .unwrap();
    let (sac, saout, saerr) = run_b3(&[
        "guard",
        "symbol-check",
        "--repo-root",
        r,
        "--base-sha",
        &base2,
    ]);
    assert_eq!(sac, 0, "orphan_internal-only must exit 0: {saout}\n{saerr}");
    assert!(saout.contains("SYMBOL_ADVISORY"), "{saout}");
    assert!(
        saout.contains("orphan_internal=src/mod_x.rs:unreferenced_priv"),
        "{saout}"
    );

    let _ = base;
    fs::write(
        repo.join("src/mod_x.rs"),
        "pub fn kept() -> i32 { 2 }\nfn unreferenced_priv() -> i32 { 3 }\n",
    )
    .unwrap();
    let (sbc, sbout, _) = run_b3(&[
        "guard",
        "symbol-check",
        "--repo-root",
        r,
        "--base-sha",
        &base2,
    ]);
    assert_eq!(sbc, 2, "dangling_refs must exit 2: {sbout}");
    assert!(sbout.contains("SYMBOL_FINDINGS"), "{sbout}");
    assert!(
        sbout.contains("dangling_refs=exported_removed_sym(1f)"),
        "{sbout}"
    );
}

#[test]
fn core_scoped_verify_and_ledger_pass_log_resist_env_and_counter_tampering() {
    let tmp = TempDirGuard::new("f39-reg");
    let repo = tmp.path.join("repo");
    init_git_repo(&repo);
    let r = repo.to_str().unwrap();

    commit_file(
        &repo,
        "Cargo.toml",
        "[package]\nname=\"demo\"\nversion=\"0.1.0\"\n",
        "manifest",
    );
    commit_file(&repo, "src/app.rs", "pub fn val() -> i32 { 1 }\n", "app");
    let base = git_in(&repo, &["rev-parse", "HEAD"]);

    // F39-01: Scoped verify receipt -> edit -> stage -> verify-check & precommit MUST reject even under GIT_LITERAL_PATHSPECS=1
    let receipt_rel = ".b3/ship/verify/scoped.verify";
    let (vrc, _, vrerr) = run_b3(&[
        "guard",
        "verify-run",
        "--repo-root",
        r,
        "--task-id",
        "T1",
        "--relevant-paths",
        "src/app.rs",
        "--receipt-path",
        receipt_rel,
        "--verify-cmd",
        "echo ok",
    ]);
    assert_eq!(vrc, 0, "verify-run failed: {vrerr}");

    fs::write(repo.join("src/app.rs"), "pub fn val() -> i32 { 999 }\n").unwrap();
    git_in(&repo, &["add", "src/app.rs"]);

    let bin = common::b3_bin();
    let vc_out = std::process::Command::new(bin)
        .args([
            "guard",
            "verify-check",
            "--repo-root",
            r,
            "--receipt-path",
            receipt_rel,
            "--expected-cmd",
            "echo ok",
            "--relevant-paths",
            "src/app.rs",
        ])
        .env("GIT_LITERAL_PATHSPECS", "1")
        .env("GIT_NOGLOB_PATHSPECS", "1")
        .output()
        .expect("run verify-check under GIT_LITERAL_PATHSPECS=1");
    assert_eq!(
        vc_out.status.code(),
        Some(2),
        "verify-check under GIT_LITERAL_PATHSPECS=1 must return 2 (VERIFY_STALE): stdout={} stderr={}",
        String::from_utf8_lossy(&vc_out.stdout),
        String::from_utf8_lossy(&vc_out.stderr)
    );

    let pc_out = std::process::Command::new(bin)
        .args([
            "guard",
            "precommit",
            "--repo-root",
            r,
            "--allowed-paths",
            "src/app.rs",
            "--require-verify-receipt",
            receipt_rel,
            "--expected-cmd",
            "echo ok",
            "--relevant-paths",
            "src/app.rs",
        ])
        .env("GIT_LITERAL_PATHSPECS", "1")
        .env("GIT_NOGLOB_PATHSPECS", "1")
        .output()
        .expect("run precommit under GIT_LITERAL_PATHSPECS=1");
    assert_eq!(
        pc_out.status.code(),
        Some(1),
        "precommit under GIT_LITERAL_PATHSPECS=1 must reject stale scoped receipt: stdout={} stderr={}",
        String::from_utf8_lossy(&pc_out.stdout),
        String::from_utf8_lossy(&pc_out.stderr)
    );

    // F39-03: 4 REVIEWED updates -> passes_used=4 -> tamper header passes_used=1 -> check & update must reject LEDGER_CORRUPT
    let ledger_rel = ".b3/ship/review-loop/f39-ledger.md";
    assert_eq!(
        run_b3(&[
            "guard",
            "review-ledger",
            "--repo-root",
            r,
            "--action",
            "init",
            "--ledger-path",
            ledger_rel,
            "--base-sha",
            &base,
            "--max-passes",
            "5",
            "--review-independence",
            "INDEPENDENT",
        ])
        .0,
        0
    );
    for _ in 0..4 {
        let (uc, _, uerr) = run_b3(&[
            "guard",
            "review-ledger",
            "--repo-root",
            r,
            "--action",
            "update",
            "--ledger-path",
            ledger_rel,
            "--unit-id",
            "U01",
            "--status",
            "REVIEWED",
        ]);
        assert_eq!(uc, 0, "ledger update failed: {uerr}");
    }
    let ledger_full = repo.join(ledger_rel);
    let raw_ledger = fs::read_to_string(&ledger_full).unwrap();
    assert!(raw_ledger.contains("passes_used=4"), "{raw_ledger}");
    let tampered_ledger = raw_ledger.replacen("passes_used=4", "passes_used=1", 1);
    fs::write(&ledger_full, tampered_ledger).unwrap();

    let (chk_c, chk_out, chk_err) = run_b3(&[
        "guard",
        "review-ledger",
        "--repo-root",
        r,
        "--action",
        "check",
        "--ledger-path",
        ledger_rel,
    ]);
    let chk_all = format!("{chk_out}\n{chk_err}");
    assert_eq!(chk_c, 1, "{chk_all}");
    assert!(chk_all.contains("LEDGER_CORRUPT:"), "{chk_all}");

    let (upd_c, upd_out, upd_err) = run_b3(&[
        "guard",
        "review-ledger",
        "--repo-root",
        r,
        "--action",
        "update",
        "--ledger-path",
        ledger_rel,
        "--unit-id",
        "U01",
        "--status",
        "REVIEWED",
    ]);
    let upd_all = format!("{upd_out}\n{upd_err}");
    assert_eq!(upd_c, 1, "{upd_all}");
    assert!(upd_all.contains("LEDGER_CORRUPT:"), "{upd_all}");
}

#[test]
fn incremental_isolated_worktree_integration_with_worker_bases_succeeds() {
    let tmp = TempDirGuard::new("inc-wt-worker-bases");
    let repo = tmp.path.join("repo");
    init_git_repo(&repo);
    let r = repo.to_str().unwrap();

    commit_file(&repo, "src/a.txt", "a-v0\n", "seed a");
    commit_file(&repo, "src/b.txt", "b-v0\n", "seed b");
    let sha_0 = commit_file(&repo, "src/e.txt", "e-v0\n", "seed e at sha_0");

    let wt_a = tmp.path.join("wt-a");
    let wt_e = tmp.path.join("wt-e");
    let wt_a_s = wt_a.to_str().unwrap();
    let wt_e_s = wt_e.to_str().unwrap();
    git_in(&repo, &["worktree", "add", "-b", "wt-a", wt_a_s, &sha_0]);
    git_in(&repo, &["worktree", "add", "-b", "wt-e", wt_e_s, &sha_0]);

    // Validate both linked isolated worktrees against Parent and each other
    let (ca, out_a, err_a) = run_b3(&[
        "guard",
        "check-worktree",
        "--repo-root",
        wt_a_s,
        "--require-isolated",
        "--expected-root",
        r,
        "--expected-base-sha",
        &sha_0,
        "--peer-roots",
        wt_e_s,
    ]);
    assert_eq!(ca, 0, "{out_a}\n{err_a}");
    assert!(out_a.contains("WORKTREE_OK"), "{out_a}");

    let (ce, out_e, err_e) = run_b3(&[
        "guard",
        "check-worktree",
        "--repo-root",
        wt_e_s,
        "--require-isolated",
        "--expected-root",
        r,
        "--expected-base-sha",
        &sha_0,
        "--peer-roots",
        wt_a_s,
    ]);
    assert_eq!(ce, 0, "{out_e}\n{err_e}");
    assert!(out_e.contains("WORKTREE_OK"), "{out_e}");

    // Worker A edits wt_a/src/a.txt while Worker E concurrently edits wt_e/src/e.txt
    fs::write(wt_a.join("src/a.txt"), "a-v1-worker-A\n").unwrap();
    fs::write(wt_e.join("src/e.txt"), "e-v1-worker-E\n").unwrap();

    // TASK_VERIFIED != DEPENDENCY_OUTPUT_AVAILABLE: before Parent integrates wt_a, Parent is still at sha_0
    let (pre_c, pre_out, pre_err) = run_b3(&[
        "guard",
        "mechanical-check",
        "--repo-root",
        r,
        "--base-sha",
        &sha_0,
        "--allowed-paths",
        "src/a.txt",
        "--wave-specs",
        "A=src/a.txt",
        "--worker-roots",
        &format!("A={wt_a_s}"),
    ]);
    assert_eq!(pre_c, 2, "{pre_out}\n{pre_err}");
    assert!(
        pre_out.contains("ownership_verification=VIOLATION"),
        "{pre_out}"
    );
    assert!(
        pre_out.contains("src/a.txt(A->content_mismatch)"),
        "{pre_out}"
    );

    // Parent integrates A from wt_a into Parent and commits sha_A to unlock dependent B; wt_e stays at sha_0
    fs::write(repo.join("src/a.txt"), "a-v1-worker-A\n").unwrap();
    let (int_a_c, int_a_out, int_a_err) = run_b3(&[
        "guard",
        "mechanical-check",
        "--repo-root",
        r,
        "--base-sha",
        &sha_0,
        "--allowed-paths",
        "src/a.txt",
        "--wave-specs",
        "A=src/a.txt",
        "--worker-roots",
        &format!("A={wt_a_s}"),
    ]);
    assert_eq!(int_a_c, 0, "{int_a_out}\n{int_a_err}");
    assert!(
        int_a_out.contains("ownership_verification=VERIFIED_PER_WORKER"),
        "{int_a_out}"
    );

    git_in(&repo, &["add", "src/a.txt"]);
    git_in(&repo, &["commit", "-m", "integrate A"]);
    let sha_a = git_in(&repo, &["rev-parse", "HEAD"]);
    assert_eq!(git_in(&wt_e, &["rev-parse", "HEAD"]), sha_0);

    // Later, Parent copies E's output into Parent (now at sha_A)
    fs::write(repo.join("src/e.txt"), "e-v1-worker-E\n").unwrap();

    // WITHOUT --worker-bases, --base-sha sha_A is not an ancestor of wt_e (still at sha_0) -> exit 2
    let (no_wb_c, no_wb_out, no_wb_err) = run_b3(&[
        "guard",
        "mechanical-check",
        "--repo-root",
        r,
        "--base-sha",
        &sha_a,
        "--allowed-paths",
        "src/e.txt",
        "--wave-specs",
        "E=src/e.txt",
        "--worker-roots",
        &format!("E={wt_e_s}"),
    ]);
    let no_wb_all = format!("{no_wb_out}\n{no_wb_err}");
    assert_eq!(no_wb_c, 2, "{no_wb_all}");
    assert!(
        no_wb_all.contains("WORKTREE_UNSAFE: base_not_ancestor_of_worker"),
        "{no_wb_all}"
    );

    // WITH --worker-bases E=<sha_0>, disjoint intervening commit sha_0..sha_A succeeds cleanly -> exit 0
    let (wb_c, wb_out, wb_err) = run_b3(&[
        "guard",
        "mechanical-check",
        "--repo-root",
        r,
        "--base-sha",
        &sha_a,
        "--allowed-paths",
        "src/e.txt",
        "--wave-specs",
        "E=src/e.txt",
        "--worker-roots",
        &format!("E={wt_e_s}"),
        "--worker-bases",
        &format!("E={sha_0}"),
    ]);
    assert_eq!(wb_c, 0, "{wb_out}\n{wb_err}");
    assert!(
        wb_out.contains("ownership_verification=VERIFIED_PER_WORKER"),
        "{wb_out}"
    );
    assert!(wb_out.contains("ownership_violations=none"), "{wb_out}");
}

#[test]
fn incremental_isolated_worktree_worker_bases_detects_stale_base_conflict_and_bad_args() {
    let tmp = TempDirGuard::new("inc-wt-stale-conflict");
    let repo = tmp.path.join("repo");
    init_git_repo(&repo);
    let r = repo.to_str().unwrap();

    commit_file(&repo, "src/a.txt", "a-v0\n", "seed a");
    let sha_0 = commit_file(&repo, "src/e.txt", "e-v0\n", "seed e at sha_0");

    let wt_e = tmp.path.join("wt-e");
    let wt_e_s = wt_e.to_str().unwrap();
    git_in(&repo, &["worktree", "add", "-b", "wt-e", wt_e_s, &sha_0]);
    fs::write(wt_e.join("src/e.txt"), "e-v1-worker-E\n").unwrap();

    // Intervening commit sha_0..sha_A on Parent ALSO modifies src/e.txt
    fs::write(repo.join("src/a.txt"), "a-v1-parent\n").unwrap();
    fs::write(repo.join("src/e.txt"), "e-intervening-parent\n").unwrap();
    git_in(&repo, &["add", "src/a.txt", "src/e.txt"]);
    git_in(
        &repo,
        &["commit", "-m", "intervening commit touching e.txt"],
    );
    let sha_a = git_in(&repo, &["rev-parse", "HEAD"]);

    // Even if Parent overwrites src/e.txt with wt_e's content, stale_base_conflict MUST fail closed (exit 2)
    fs::write(repo.join("src/e.txt"), "e-v1-worker-E\n").unwrap();
    let (sc_c, sc_out, sc_err) = run_b3(&[
        "guard",
        "mechanical-check",
        "--repo-root",
        r,
        "--base-sha",
        &sha_a,
        "--allowed-paths",
        "src/e.txt",
        "--wave-specs",
        "E=src/e.txt",
        "--worker-roots",
        &format!("E={wt_e_s}"),
        "--worker-bases",
        &format!("E={sha_0}"),
    ]);
    assert_eq!(sc_c, 2, "{sc_out}\n{sc_err}");
    assert!(
        sc_out.contains("ownership_verification=VIOLATION"),
        "{sc_out}"
    );
    assert!(
        sc_out.contains("src/e.txt(E->stale_base_conflict)"),
        "{sc_out}"
    );

    // --worker-bases without --worker-roots MUST fail closed with exit 1
    let (bad_c, bad_out, bad_err) = run_b3(&[
        "guard",
        "mechanical-check",
        "--repo-root",
        r,
        "--base-sha",
        &sha_a,
        "--allowed-paths",
        "src/e.txt",
        "--wave-specs",
        "E=src/e.txt",
        "--worker-bases",
        &format!("E={sha_0}"),
    ]);
    let bad_all = format!("{bad_out}\n{bad_err}");
    assert_eq!(bad_c, 1, "{bad_all}");
    assert!(
        bad_all.contains("MECHANICAL_FAIL: -WorkerBases requires -WorkerRoots"),
        "{bad_all}"
    );

    // Divergent worker_base (ancestor of wt_e HEAD, but NOT ancestor of Parent sha_A) -> exit 2
    let sha_div = commit_file(&wt_e, "src/e.txt", "e-diverged-branch\n", "divergent wt-e");
    let (na_c, na_out, na_err) = run_b3(&[
        "guard",
        "mechanical-check",
        "--repo-root",
        r,
        "--base-sha",
        &sha_a,
        "--allowed-paths",
        "src/e.txt",
        "--wave-specs",
        "E=src/e.txt",
        "--worker-roots",
        &format!("E={wt_e_s}"),
        "--worker-bases",
        &format!("E={sha_div}"),
    ]);
    let na_all = format!("{na_out}\n{na_err}");
    assert_eq!(na_c, 2, "{na_all}");
    assert!(
        na_all.contains("worker_base_not_ancestor_of_parent"),
        "{na_all}"
    );
}

#[test]
fn mid_wave_resume_preserves_fresh_receipts_and_invalidates_only_stale_approaches() {
    let tmp = TempDirGuard::new("mid-wave-resume");
    let repo = tmp.path.join("repo");
    init_git_repo(&repo);
    let r = repo.to_str().unwrap();

    commit_file(&repo, "src/a.txt", "a-v0\n", "seed a");
    commit_file(&repo, "src/b.txt", "b-v0\n", "seed b");
    commit_file(&repo, "src/c.txt", "c-v0\n", "seed c");
    let sha_0 = commit_file(&repo, "src/e.txt", "e-v0\n", "seed e at sha_0");

    // Task A modifies src/a.txt and records scoped verification receipt a.verify
    fs::write(repo.join("src/a.txt"), "a-v1-verified\n").unwrap();
    let a_receipt = ".b3/ship/runs/r1/a.verify";
    let (vr_c, vr_out, vr_err) = run_b3(&[
        "guard",
        "verify-run",
        "--repo-root",
        r,
        "--task-id",
        "A",
        "--verify-cmd",
        "echo ok",
        "--receipt-path",
        a_receipt,
        "--relevant-paths",
        "src/a.txt",
    ]);
    assert_eq!(vr_c, 0, "{vr_out}\n{vr_err}");

    // Task E is active mid-wave and modifies src/e.txt (uncommitted)
    fs::write(repo.join("src/e.txt"), "e-v1-in-flight\n").unwrap();

    // 1. Resume check on A's receipt stays VERIFY_VALID despite E's uncommitted edit in src/e.txt
    let (vc_c, vc_out, vc_err) = run_b3(&[
        "guard",
        "verify-check",
        "--repo-root",
        r,
        "--receipt-path",
        a_receipt,
        "--expected-cmd",
        "echo ok",
        "--relevant-paths",
        "src/a.txt",
    ]);
    assert_eq!(vc_c, 0, "{vc_out}\n{vc_err}");
    assert!(vc_out.contains("VERIFY_VALID"), "{vc_out}");

    // 2. Task C (approach at sha_0, watching src/c.txt) stays FRESH when ignoring A & E's wave edits
    let (fc_c, fc_out, fc_err) = run_b3(&[
        "guard",
        "check-freshness",
        "--repo-root",
        r,
        "--approach-at-sha",
        &sha_0,
        "--task-base-sha",
        &sha_0,
        "--watched-paths",
        "src/c.txt",
        "--owned-files",
        "src/c.txt",
        "--ignore-dirty-paths",
        "src/a.txt,src/e.txt",
    ]);
    assert_eq!(fc_c, 0, "{fc_out}\n{fc_err}");
    assert!(fc_out.contains("FRESH"), "{fc_out}");

    // 3. Task B (approach at sha_0, watching src/a.txt,src/b.txt) is STALE because src/a.txt changed since sha_0
    let (fb_c, fb_out, fb_err) = run_b3(&[
        "guard",
        "check-freshness",
        "--repo-root",
        r,
        "--approach-at-sha",
        &sha_0,
        "--task-base-sha",
        &sha_0,
        "--watched-paths",
        "src/a.txt,src/b.txt",
        "--owned-files",
        "src/b.txt",
        "--ignore-dirty-paths",
        "src/e.txt",
    ]);
    let fb_all = format!("{fb_out}\n{fb_err}");
    assert_eq!(fb_c, 2, "{fb_all}");
    assert!(fb_all.contains("STALE"), "{fb_all}");
    assert!(fb_all.contains("src/a.txt"), "{fb_all}");

    // Even after A commits (sha_0 -> sha_A) while E remains dirty, C stays FRESH and B stays STALE
    git_in(&repo, &["add", "src/a.txt"]);
    git_in(&repo, &["commit", "-m", "commit A"]);

    let (fc2_c, fc2_out, fc2_err) = run_b3(&[
        "guard",
        "check-freshness",
        "--repo-root",
        r,
        "--approach-at-sha",
        &sha_0,
        "--task-base-sha",
        &sha_0,
        "--watched-paths",
        "src/c.txt",
        "--owned-files",
        "src/c.txt",
        "--ignore-dirty-paths",
        "src/e.txt",
    ]);
    assert_eq!(fc2_c, 0, "{fc2_out}\n{fc2_err}");
    assert!(fc2_out.contains("FRESH"), "{fc2_out}");

    let (fb2_c, fb2_out, fb2_err) = run_b3(&[
        "guard",
        "check-freshness",
        "--repo-root",
        r,
        "--approach-at-sha",
        &sha_0,
        "--task-base-sha",
        &sha_0,
        "--watched-paths",
        "src/a.txt,src/b.txt",
        "--owned-files",
        "src/b.txt",
        "--ignore-dirty-paths",
        "src/e.txt",
    ]);
    let fb2_all = format!("{fb2_out}\n{fb2_err}");
    assert_eq!(fb2_c, 2, "{fb2_all}");
    assert!(fb2_all.contains("STALE"), "{fb2_all}");
    assert!(fb2_all.contains("src/a.txt"), "{fb2_all}");
}
