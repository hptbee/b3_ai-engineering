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
