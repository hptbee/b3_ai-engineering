//! Cross-platform behavioral and security integration tests for `b3 guard` and `b3 install product`.
//! Migrates all unique coverage from legacy guard, context-routing, tshirt-hierarchical,
//! research-ship, smoke-ship-product, and ship-behavior suites using fast Rust repo cloning
//! and in-memory fixture generation.

mod common;

use common::{
    clone_seeded_git_repo, git_in, git_in_status, init_fresh_git_repo, run_b3 as raw_run_b3,
    run_b3_env as raw_run_b3_env, write_lf, write_mock_gh, TempDirGuard,
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

fn create_dir_link(link: &Path, target: &Path) {
    if let Some(parent) = link.parent() {
        fs::create_dir_all(parent).expect("create link parent");
    }
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(target, link).expect("create unix dir symlink");
    }
    #[cfg(windows)]
    {
        let link_win = link.to_string_lossy().replace('/', "\\");
        let target_win = target.to_string_lossy().replace('/', "\\");
        let status = std::process::Command::new("cmd")
            .args(["/d", "/c", "mklink", "/J", &link_win, &target_win])
            .status()
            .expect("invoke mklink /J");
        assert!(status.success(), "mklink /J failed for {link_win}");
    }
}

fn remove_dir_link_only(link: &Path) {
    #[cfg(windows)]
    {
        let _ = fs::remove_dir(link);
    }
    #[cfg(not(windows))]
    {
        let _ = fs::remove_file(link);
    }
}

fn create_file_link(link: &Path, target: &Path) {
    if let Some(parent) = link.parent() {
        fs::create_dir_all(parent).expect("create file link parent");
    }
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(target, link).expect("create unix file symlink");
    }
    #[cfg(windows)]
    {
        // Try file symlink first; if unprivileged Windows blocks file symlinks, fall back to a
        // directory junction on the parent container when tests use a subdir link.
        if std::os::windows::fs::symlink_file(target, link).is_err() {
            panic!(
                "symlink_file failed for {}; use directory junction for Windows tests",
                link.display()
            );
        }
    }
}

fn verify_cmd_fail(code: i32, msg: &str) -> String {
    if cfg!(windows) {
        format!("Write-Output '{msg}'; exit {code}")
    } else {
        format!("echo '{msg}'; exit {code}")
    }
}

fn verify_cmd_big_fail() -> String {
    if cfg!(windows) {
        "1..1500 | ForEach-Object { 10001..10010 -join 9 }; exit 2".to_string()
    } else {
        "awk 'BEGIN{for(i=1;i<=1500;i++) print \"10001910002910003910004910005910006910007910008910009910010\"}'; exit 2".to_string()
    }
}

fn verify_cmd_touch_sentinel(sentinel: &Path) -> String {
    let s = sentinel.to_string_lossy().replace('\\', "/");
    if cfg!(windows) {
        format!("Set-Content '{s}' 'ran'; exit 0")
    } else {
        format!("touch '{s}'")
    }
}

fn path_with_prepended(dir: &Path) -> String {
    let cur = std::env::var_os("PATH").unwrap_or_default();
    let mut parts = vec![dir.to_path_buf()];
    parts.extend(std::env::split_paths(&cur));
    std::env::join_paths(parts)
        .expect("join PATH")
        .to_string_lossy()
        .into_owned()
}

fn extract_kv<'a>(text: &'a str, key: &str) -> Option<&'a str> {
    let prefix = format!("{key}=");
    text.lines().find_map(|l| l.trim().strip_prefix(&prefix))
}

fn parse_unit_ids_by_files(ledger_text: &str) -> std::collections::HashMap<String, String> {
    let mut map = std::collections::HashMap::new();
    for line in ledger_text.lines() {
        let trimmed = line.trim();
        if !trimmed.starts_with('|') {
            continue;
        }
        let cols: Vec<&str> = trimmed.split('|').map(str::trim).collect();
        if cols.len() >= 13 && cols[1].starts_with('U') {
            map.insert(cols[12].to_string(), cols[1].to_string());
        }
    }
    map
}

#[cfg(windows)]
fn to_windows_short_path(path: &Path) -> Option<std::path::PathBuf> {
    use std::ffi::OsString;
    use std::os::windows::ffi::{OsStrExt, OsStringExt};

    extern "system" {
        fn GetShortPathNameW(
            lpsz_long_path: *const u16,
            lpsz_short_path: *mut u16,
            cch_buffer: u32,
        ) -> u32;
    }

    let wide: Vec<u16> = path
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect();
    let needed = unsafe { GetShortPathNameW(wide.as_ptr(), std::ptr::null_mut(), 0) };
    if needed == 0 {
        return None;
    }
    let mut buf = vec![0u16; needed as usize];
    let written = unsafe { GetShortPathNameW(wide.as_ptr(), buf.as_mut_ptr(), needed) };
    if written == 0 || written >= needed {
        return None;
    }
    Some(std::path::PathBuf::from(OsString::from_wide(
        &buf[..written as usize],
    )))
}

#[test]
fn standalone_verify_provenance_containment_and_large_output() {
    let tmp = TempDirGuard::new("guard-verify-prov");
    let repo = tmp.path.join("repo");
    clone_seeded_git_repo(&repo);
    write_lf(&repo.join("src/a.ts"), "export const a = 1;\n");
    write_lf(&repo.join("package.json"), "{\"name\":\"x\"}\n");
    git_in(&repo, &["add", "."]);
    git_in(&repo, &["commit", "-qm", "seed"]);
    let head = git_in(&repo, &["rev-parse", "HEAD"]);
    let r_str = repo.to_str().unwrap();

    // 1. Seed valid receipt + provenance validation
    let (c, out, err) = run_b3(&[
        "guard",
        "verify-run",
        "--repo-root",
        r_str,
        "--verify-cmd",
        "echo prov-ok",
        "--receipt-path",
        ".b3/ship/verify/seed.verify",
        "--relevant-paths",
        "src/a.ts",
    ]);
    assert_eq!(c, 0, "seed verify-run failed: {out}\n{err}");
    assert!(out.contains("VERIFY_PASS:"), "out={out}");

    let (c, out, _) = run_b3(&[
        "guard",
        "verify-check",
        "--repo-root",
        r_str,
        "--receipt-path",
        ".b3/ship/verify/seed.verify",
    ]);
    assert_eq!(c, 0, "seed verify-check failed: {out}");
    assert!(out.contains("VERIFY_VALID:"), "out={out}");

    let seed_raw = fs::read_to_string(repo.join(".b3/ship/verify/seed.verify")).unwrap();
    let tree_sha = extract_kv(&seed_raw, "tree_hash").unwrap().to_string();

    let outside_dir = tmp.path.join("outside-logs");
    fs::create_dir_all(&outside_dir).unwrap();
    write_lf(&tmp.path.join("escape.log"), "outside repo\n");
    write_lf(&outside_dir.join("secret.log"), "outside secret\n");
    let junc = repo.join(".b3/ship/verify/extlink");
    create_dir_link(&junc, &outside_dir);

    let bad_dir = repo.join(".b3/ship/verify");
    write_lf(
        &bad_dir.join("nocmd.verify"),
        &format!("schema=b3-verify-v1\ntask_id=t1\nscope=scoped\nhead_sha={head}\ntree_hash={tree_sha}\nrelevant_paths=src/a.ts\nexit_code=0\nstatus=PASS\nlog_path=none\ntimestamp_utc=2026-11-22T10:00:00Z\n"),
    );
    write_lf(
        &bad_dir.join("badts.verify"),
        &format!("schema=b3-verify-v1\ntask_id=t1\nscope=scoped\nhead_sha={head}\ntree_hash={tree_sha}\nrelevant_paths=src/a.ts\nexit_code=0\nstatus=PASS\ncommand=echo ok\nlog_path=none\ntimestamp_utc=bad-time\n"),
    );
    write_lf(
        &bad_dir.join("misslog.verify"),
        &format!("schema=b3-verify-v1\ntask_id=t1\nscope=scoped\nhead_sha={head}\ntree_hash={tree_sha}\nrelevant_paths=src/a.ts\nexit_code=0\nstatus=PASS\ncommand=echo ok\nlog_path=.b3/ship/verify/missing.log\ntimestamp_utc=2026-11-22T10:00:00Z\n"),
    );
    for (name, lp) in [
        ("travlog.verify", "../escape.log"),
        ("abslog.verify", "/etc/passwd"),
        ("junclog.verify", ".b3/ship/verify/extlink/secret.log"),
        ("gitlog1.verify", ".git/HEAD"),
        ("gitlog2.verify", "././.git/HEAD"),
        ("gitlog3.verify", ".GIT/HEAD"),
    ] {
        write_lf(
            &bad_dir.join(name),
            &format!("schema=b3-verify-v1\ntask_id=t1\nscope=scoped\nhead_sha={head}\ntree_hash={tree_sha}\nrelevant_paths=src/a.ts\nexit_code=0\nstatus=PASS\ncommand=echo ok\nlog_path={lp}\ntimestamp_utc=2026-11-22T10:00:00Z\n"),
        );
    }

    for (rel, expect) in [
        (
            ".b3/ship/verify/nocmd.verify",
            "VERIFY_CORRUPT: missing field 'command'",
        ),
        (
            ".b3/ship/verify/badts.verify",
            "VERIFY_CORRUPT: invalid timestamp_utc",
        ),
        (
            ".b3/ship/verify/misslog.verify",
            "VERIFY_CORRUPT: missing log_path",
        ),
        (
            ".b3/ship/verify/travlog.verify",
            "VERIFY_CORRUPT: invalid log_path",
        ),
        (
            ".b3/ship/verify/abslog.verify",
            "VERIFY_CORRUPT: invalid log_path",
        ),
        (
            ".b3/ship/verify/junclog.verify",
            "VERIFY_CORRUPT: invalid log_path",
        ),
        (
            ".b3/ship/verify/gitlog1.verify",
            "VERIFY_CORRUPT: invalid log_path",
        ),
        (
            ".b3/ship/verify/gitlog2.verify",
            "VERIFY_CORRUPT: invalid log_path",
        ),
        (
            ".b3/ship/verify/gitlog3.verify",
            "VERIFY_CORRUPT: invalid log_path",
        ),
    ] {
        let (rc, rout, rerr) = run_b3(&[
            "guard",
            "verify-check",
            "--repo-root",
            r_str,
            "--receipt-path",
            rel,
        ]);
        assert_eq!(rc, 1, "expected 1 for {rel}: {rout}\n{rerr}");
        assert!(
            rerr.contains(expect) || rout.contains(expect),
            "{rel}: {rout}\n{rerr}"
        );
    }

    // 2. R016 Pre-execution containment: sentinel MUST NEVER be created
    let sentinel = tmp.path.join("sentinel-never-ran.txt");
    let sentinel_cmd = verify_cmd_touch_sentinel(&sentinel);
    let abs_esc_log = tmp.path.join("escape-run.log");
    let abs_esc_rec = tmp.path.join("escape-rec.verify");
    let dot_rec = repo.join("file.");
    fs::create_dir_all(repo.join(".b3/ship/dirrec")).unwrap();

    for bad_log in [
        "../escape-run.log",
        abs_esc_log.to_str().unwrap(),
        ".b3/ship/verify/extlink/evil-run.log",
    ] {
        let (lc, lout, lerr) = run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            r_str,
            "--verify-cmd",
            &sentinel_cmd,
            "--receipt-path",
            ".b3/ship/verify/ok.verify",
            "--log-path",
            bad_log,
        ]);
        assert_eq!(lc, 1, "bad log {bad_log}: {lout}\n{lerr}");
        assert!(
            lerr.contains("VERIFY_RUN_FAIL: invalid log_path"),
            "{bad_log}: {lerr}"
        );
    }
    for bad_rec in [
        "../escape-rec.verify",
        abs_esc_rec.to_str().unwrap(),
        ".git/evil.verify",
        ".git./hooks/probe",
        "sub/.git/config",
        dot_rec.to_str().unwrap(),
        "/c/tmp/.git./x",
        ".b3/ship/verify/extlink/evil.verify",
        ".b3/ship/dirrec",
    ] {
        let (rc, rout, rerr) = run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            r_str,
            "--verify-cmd",
            &sentinel_cmd,
            "--receipt-path",
            bad_rec,
        ]);
        assert_eq!(rc, 1, "bad rec {bad_rec}: {rout}\n{rerr}");
        assert!(
            rerr.contains("VERIFY_RUN_FAIL: invalid receipt_path"),
            "{bad_rec}: {rerr}"
        );
    }
    assert!(
        !sentinel.exists(),
        "pre-execution containment failed: verify_cmd ran!"
    );
    assert!(!abs_esc_log.exists());
    assert!(!abs_esc_rec.exists());
    assert!(!outside_dir.join("evil-run.log").exists());
    assert!(!repo.join(".git/evil.verify").exists());
    remove_dir_link_only(&junc);

    // 3. Relative/nested CWD canonicalization stores repo-relative log_path
    #[cfg(unix)]
    let canon_repo = fs::canonicalize(&repo).unwrap_or_else(|_| repo.clone());
    #[cfg(not(unix))]
    let canon_repo = repo.clone();
    let abs_rec = canon_repo.join(".b3/ship/verify/relroot.verify");
    let abs_log = canon_repo.join(".b3/ship/verify/relroot.log");
    let relroot_cmd = if cfg!(windows) {
        "1..40 | ForEach-Object { \"line-$_\" }"
    } else {
        "i=1; while [ $i -le 40 ]; do echo line-$i; i=$((i+1)); done"
    };
    let (rc, rout, rerr) = run_b3_env(
        &[
            "guard",
            "verify-run",
            "--verify-cmd",
            relroot_cmd,
            "--receipt-path",
            abs_rec.to_str().unwrap(),
            "--log-path",
            abs_log.to_str().unwrap(),
            "--relevant-paths",
            "src/a.ts",
        ],
        Some(&canon_repo),
        &[],
        &[],
    );
    assert_eq!(rc, 0, "relroot verify-run failed: {rout}\n{rerr}");
    let rel_txt = fs::read_to_string(&abs_rec).unwrap();
    assert!(
        rel_txt.contains("log_path=.b3/ship/verify/relroot.log\n"),
        "expected repo-relative log_path: {rel_txt}"
    );
    let (cc, _, _) = run_b3(&[
        "guard",
        "verify-check",
        "--repo-root",
        r_str,
        "--receipt-path",
        ".b3/ship/verify/relroot.verify",
    ]);
    assert_eq!(cc, 0);

    // 4. Command mismatch, scope mismatch, ALL coverage -> VERIFY_STALE on dependency edit
    let (_, _, merr) = run_b3(&[
        "guard",
        "verify-check",
        "--repo-root",
        r_str,
        "--receipt-path",
        ".b3/ship/verify/seed.verify",
        "--expected-cmd",
        "echo other",
    ]);
    assert!(merr.contains("VERIFY_MISMATCH: command mismatch"), "{merr}");

    let (_, _, serr) = run_b3(&[
        "guard",
        "verify-check",
        "--repo-root",
        r_str,
        "--receipt-path",
        ".b3/ship/verify/seed.verify",
        "--relevant-paths",
        "src/a.ts,package.json",
    ]);
    assert!(
        serr.contains("VERIFY_SCOPE_MISMATCH: uncovered path (package.json)"),
        "{serr}"
    );

    let (ac, _, _) = run_b3(&[
        "guard",
        "verify-run",
        "--repo-root",
        r_str,
        "--verify-cmd",
        "echo full-suite",
        "--receipt-path",
        ".b3/ship/verify/all.verify",
    ]);
    assert_eq!(ac, 0);
    let (ac2, _, _) = run_b3(&[
        "guard",
        "verify-check",
        "--repo-root",
        r_str,
        "--receipt-path",
        ".b3/ship/verify/all.verify",
        "--expected-cmd",
        "echo full-suite",
        "--relevant-paths",
        "src/a.ts,package.json",
    ]);
    assert_eq!(ac2, 0);
    write_lf(&repo.join("package.json"), "{\"name\":\"x\",\"v\":2}\n");
    let (sc, sout, serr) = run_b3(&[
        "guard",
        "verify-check",
        "--repo-root",
        r_str,
        "--receipt-path",
        ".b3/ship/verify/all.verify",
        "--relevant-paths",
        "src/a.ts,package.json",
    ]);
    assert_eq!(sc, 2);
    assert!(
        serr.contains("VERIFY_STALE:") || sout.contains("VERIFY_STALE:"),
        "{sout}\n{serr}"
    );

    // 5. Failing verify-run writes FAIL receipt + log -> VERIFY_FAILED_RECEIPT; >64KB output truncation (<=36 stdout/stderr lines + full .log persisted)
    let fail_cmd = verify_cmd_fail(3, "bad-check");
    let (fc, fout, ferr) = run_b3(&[
        "guard",
        "verify-run",
        "--repo-root",
        r_str,
        "--verify-cmd",
        &fail_cmd,
        "--receipt-path",
        ".b3/ship/verify/fail.verify",
        "--task-id",
        "TFAIL",
    ]);
    assert_eq!(fc, 1, "{fout}\n{ferr}");
    assert!(
        ferr.contains("VERIFY_FAIL:") || fout.contains("VERIFY_FAIL:"),
        "{fout}\n{ferr}"
    );
    assert!(repo.join(".b3/ship/verify/fail.verify.log").is_file());
    let (vfc, _, vferr) = run_b3(&[
        "guard",
        "verify-check",
        "--repo-root",
        r_str,
        "--receipt-path",
        ".b3/ship/verify/fail.verify",
    ]);
    assert_eq!(vfc, 1);
    assert!(vferr.contains("VERIFY_FAILED_RECEIPT:"), "{vferr}");

    let big_cmd = verify_cmd_big_fail();
    let (bc, bout, berr) = raw_run_b3(&[
        "guard",
        "verify-run",
        "--repo-root",
        r_str,
        "--verify-cmd",
        &big_cmd,
        "--receipt-path",
        ".b3/ship/verify/big.verify",
    ]);
    assert_eq!(bc, 1, "big output verify-run must exit 1: {bout}\n{berr}");
    let combined = format!("{bout}\n{berr}");
    assert!(combined.contains("VERIFY_FAIL: exit=2 "), "{combined}");
    assert!(
        combined.lines().count() <= 36,
        "output lines exceeded 36: {}",
        combined.lines().count()
    );
    let big_log = fs::read_to_string(repo.join(".b3/ship/verify/big.verify.log")).unwrap();
    assert!(
        big_log.lines().count() >= 1500,
        "full log truncated: {}",
        big_log.lines().count()
    );

    // 6. Broken git binary fails closed on verify-check
    let bad_git_dir = tmp.path.join("bad-git-bin");
    write_mock_gh(
        &bad_git_dir,
        "git",
        "process.stderr.write('fatal: simulated git failure\\n'); process.exit(128);\n",
    );
    let bad_path = path_with_prepended(&bad_git_dir);
    let (gc, gout, gerr) = run_b3_env(
        &[
            "guard",
            "verify-check",
            "--repo-root",
            r_str,
            "--receipt-path",
            ".b3/ship/verify/seed.verify",
        ],
        None,
        &[("PATH", &bad_path)],
        &[],
    );
    assert_ne!(
        gc, 0,
        "verify-check must fail closed on broken git binary: {gout}\n{gerr}"
    );
}

#[test]
fn snapshot_safety_and_ignored_b3_isolation() {
    let tmp = TempDirGuard::new("guard-snap-iso");
    let repo = tmp.path.join("repo");
    clone_seeded_git_repo(&repo);
    write_lf(&repo.join(".gitignore"), ".b3/\n");
    write_lf(&repo.join("main.ts"), "export const baseline = 1;\n");
    git_in(&repo, &["add", ".gitignore", "main.ts"]);
    git_in(&repo, &["commit", "-qm", "baseline"]);
    let base = git_in(&repo, &["rev-parse", "HEAD"]);
    let r_str = repo.to_str().unwrap();

    // 1. Clean snapshot + cleared diff -> CLEAN_AFTER_FIX then EMPTY_DIFF
    write_lf(&repo.join("temporary.ts"), "temporary change\n");
    let (sc, snap, serr) = run_b3(&["guard", "snapshot", "--repo-root", r_str]);
    assert_eq!(sc, 0, "{serr}");
    let snap = snap.trim();
    assert_eq!(snap.len(), 40);
    assert!(git_in(&repo, &["stash", "list"]).is_empty());

    fs::remove_file(repo.join("temporary.ts")).unwrap();
    let (dc, dout, _) = run_b3(&[
        "guard",
        "diff-scope",
        "--repo-root",
        r_str,
        "--base-sha",
        &base,
        "--prev-sha",
        snap,
    ]);
    assert_eq!(dc, 0);
    assert!(dout.contains("size_class=CLEAN_AFTER_FIX"), "{dout}");
    assert!(dout.contains("delta_files=temporary.ts"), "{dout}");

    let (ec, _, eerr) = run_b3(&[
        "guard",
        "diff-scope",
        "--repo-root",
        r_str,
        "--base-sha",
        &base,
    ]);
    assert_eq!(ec, 2);
    assert!(eerr.contains("EMPTY_DIFF"), "{eerr}");

    // 2. Failed snapshot on credentials.json and .env leaves zero new .git/objects
    for (fname, body) in [
        ("credentials.json", "{\"secret\":\"snapshot-test-unique\"}"),
        (".env", "API_SECRET=12345\n"),
    ] {
        write_lf(&repo.join(fname), body);
        let oid = git_in(&repo, &["hash-object", "--", fname]);
        let (fc, fout, ferr) = run_b3(&["guard", "snapshot", "--repo-root", r_str]);
        assert_eq!(fc, 1, "{fname}: {fout}\n{ferr}");
        assert!(
            ferr.contains("sensitive path cannot be snapshotted"),
            "{ferr}"
        );
        let (cat_c, _, _) = git_in_status(&repo, &["cat-file", "-e", &oid]);
        assert_ne!(cat_c, 0, "secret blob {fname} was written to .git/objects!");
        fs::remove_file(repo.join(fname)).unwrap();
    }

    // 3. Ignored .b3/worktrees and review-loop state ignored in snapshot, diff-scope, verify-check, mechanical-check
    write_lf(
        &repo.join(".b3/worktrees/w1/scratch.txt"),
        "worktree scratch\n",
    );
    write_lf(&repo.join(".b3/ship/review-loop/r1/state.md"), "iter: 1\n");
    write_lf(&repo.join("src/app.ts"), "export const v = 2;\n");

    let (vc1, _, _) = run_b3(&[
        "guard",
        "verify-run",
        "--repo-root",
        r_str,
        "--verify-cmd",
        "echo iso-ok",
        "--receipt-path",
        ".b3/ship/verify/claim.verify",
        "--relevant-paths",
        "src/app.ts",
    ]);
    assert_eq!(vc1, 0);
    write_lf(&repo.join(".b3/ship/review-loop/r1/state.md"), "iter: 2\n");
    let (vchk, _, _) = run_b3(&[
        "guard",
        "verify-check",
        "--repo-root",
        r_str,
        "--receipt-path",
        ".b3/ship/verify/claim.verify",
    ]);
    assert_eq!(vchk, 0);

    let (ig_snap_c, ig_snap, ig_err) = run_b3(&["guard", "snapshot", "--repo-root", r_str]);
    assert_eq!(ig_snap_c, 0, "{ig_err}");
    let tree_list = git_in(&repo, &["ls-tree", "-r", "--name-only", ig_snap.trim()]);
    assert!(!tree_list.contains(".b3/"), "tree leaked .b3: {tree_list}");

    let (ds_c, ds_out, _) = run_b3(&[
        "guard",
        "diff-scope",
        "--repo-root",
        r_str,
        "--base-sha",
        &base,
    ]);
    assert_eq!(ds_c, 0);
    assert!(ds_out.contains("review_files=src/app.ts"), "{ds_out}");
    assert!(!ds_out.contains(".b3/"), "{ds_out}");

    let (mc_c, mc_out, _) = run_b3(&[
        "guard",
        "mechanical-check",
        "--repo-root",
        r_str,
        "--base-sha",
        &base,
        "--allowed-paths",
        "src/app.ts",
    ]);
    assert_eq!(mc_c, 0, "{mc_out}");
    assert!(mc_out.contains("MECHANICAL_OK"), "{mc_out}");

    // Staging .b3 checkpoint forcefully must block precommit
    git_in(&repo, &["add", "-f", ".b3/ship/review-loop/r1/state.md"]);
    let (pc_c, _, pc_err) = run_b3(&[
        "guard",
        "precommit",
        "--repo-root",
        r_str,
        "--allowed-paths",
        "src/app.ts,.b3/ship/review-loop/r1/state.md",
    ]);
    assert_eq!(pc_c, 1);
    assert!(pc_err.contains("checkpoint staged"), "{pc_err}");
}

#[test]
fn precommit_and_receipt_git_invariants() {
    let tmp = TempDirGuard::new("guard-pc-git");
    let repo = tmp.path.join("repo");
    clone_seeded_git_repo(&repo);
    write_lf(&repo.join("src/a.ts"), "export const a = 1;\n");
    write_lf(&repo.join("src/b.ts"), "export const b = 1;\n");
    write_lf(&repo.join("src/c.ts"), "export const c = 1;\n");
    write_lf(&repo.join("src/del.ts"), "export const d = 1;\n");
    write_lf(
        &repo.join("src/[id]/page.tsx"),
        "export const Page = () => 1;\n",
    );
    write_lf(&repo.join("src/café.ts"), "export const cafe = 1;\n");
    write_lf(&repo.join("docs/tài liệu [1] spaced.md"), "uni1\n");
    write_lf(&repo.join("docs/ lead.md"), "lead1\n");
    write_lf(&repo.join("config/.env.example"), "TOKEN=placeholder\n");
    git_in(&repo, &["add", "."]);
    git_in(&repo, &["commit", "-qm", "seed"]);
    let base = git_in(&repo, &["rev-parse", "HEAD"]);
    let r_str = repo.to_str().unwrap();

    // 1. Parallel wave HEAD advance ancestry + amend invalidation
    write_lf(&repo.join("src/a.ts"), "export const a = 2;\n");
    write_lf(&repo.join("src/b.ts"), "export const b = 2;\n");
    let r_t1 = ".b3/ship/verify/T001.verify";
    let r_t2 = ".b3/ship/verify/T002.verify";
    let r_all = ".b3/ship/verify/ALL.verify";
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            r_str,
            "--verify-cmd",
            "echo t1",
            "--receipt-path",
            r_t1,
            "--task-id",
            "T001",
            "--relevant-paths",
            "src/a.ts"
        ])
        .0,
        0
    );
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            r_str,
            "--verify-cmd",
            "echo t2",
            "--receipt-path",
            r_t2,
            "--task-id",
            "T002",
            "--relevant-paths",
            "src/b.ts"
        ])
        .0,
        0
    );
    git_in(&repo, &["add", "src/a.ts"]);
    assert_eq!(
        run_b3(&[
            "guard",
            "precommit",
            "--repo-root",
            r_str,
            "--allowed-paths",
            "src/a.ts",
            "--require-verify-receipt",
            r_t1
        ])
        .0,
        0
    );
    git_in(&repo, &["commit", "-qm", "T001"]);
    // After H0 -> H1 commit, T002 receipt remains valid!
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-check",
            "--repo-root",
            r_str,
            "--receipt-path",
            r_t2
        ])
        .0,
        0
    );
    git_in(&repo, &["add", "src/b.ts"]);
    assert_eq!(
        run_b3(&[
            "guard",
            "precommit",
            "--repo-root",
            r_str,
            "--allowed-paths",
            "src/b.ts",
            "--require-verify-receipt",
            r_t2
        ])
        .0,
        0
    );
    git_in(&repo, &["commit", "-qm", "T002"]);

    write_lf(&repo.join("src/c.ts"), "export const c = 2;\n");
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            r_str,
            "--verify-cmd",
            "echo all",
            "--receipt-path",
            r_all,
            "--task-id",
            "FINAL"
        ])
        .0,
        0
    );
    git_in(&repo, &["add", "src/c.ts"]);
    assert_eq!(
        run_b3(&[
            "guard",
            "precommit",
            "--repo-root",
            r_str,
            "--allowed-paths",
            "src/c.ts",
            "--require-verify-receipt",
            r_all
        ])
        .0,
        0
    );
    git_in(&repo, &["commit", "-qm", "T003"]);
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-check",
            "--repo-root",
            r_str,
            "--receipt-path",
            r_all
        ])
        .0,
        0
    );

    // History rewrite via amend invalidates ancestry even with identical tree content
    let r_amend = ".b3/ship/verify/amend.verify";
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            r_str,
            "--verify-cmd",
            "echo ok",
            "--receipt-path",
            r_amend,
            "--relevant-paths",
            "src/c.ts"
        ])
        .0,
        0
    );
    git_in(&repo, &["commit", "--amend", "-q", "-m", "T003-amended"]);
    let (am_c, _, am_err) = run_b3(&[
        "guard",
        "verify-check",
        "--repo-root",
        r_str,
        "--receipt-path",
        r_amend,
    ]);
    assert_eq!(am_c, 2);
    assert!(am_err.contains("VERIFY_STALE:"), "{am_err}");

    // 2. H-03 BROKEN_STAGED_CONTENT with WT == HEAD -> VERIFY_STALE + precommit mismatch
    let r_h03 = ".b3/ship/verify/h03.verify";
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            r_str,
            "--verify-cmd",
            "echo h03",
            "--receipt-path",
            r_h03,
            "--relevant-paths",
            "src/a.ts"
        ])
        .0,
        0
    );
    write_lf(&repo.join("src/a.ts"), "BROKEN_STAGED_CONTENT\n");
    git_in(&repo, &["add", "src/a.ts"]);
    write_lf(&repo.join("src/a.ts"), "export const a = 2;\n");
    let (h03_c, _, h03_err) = run_b3(&[
        "guard",
        "verify-check",
        "--repo-root",
        r_str,
        "--receipt-path",
        r_h03,
    ]);
    assert_eq!(h03_c, 2);
    assert!(h03_err.contains("VERIFY_STALE:"), "{h03_err}");
    let (h03_pc, _, h03_pc_err) = run_b3(&[
        "guard",
        "precommit",
        "--repo-root",
        r_str,
        "--allowed-paths",
        "src/a.ts",
        "--require-verify-receipt",
        r_h03,
    ]);
    assert_eq!(h03_pc, 1);
    assert!(
        h03_pc_err.contains("staged content differs from working tree"),
        "{h03_pc_err}"
    );
    git_in(&repo, &["reset", "-q", "HEAD", "src/a.ts"]);

    // 3. Partial staging + git rm --cached + R006 IgnoreDirtyPaths mismatch vs staged-ignored block
    write_lf(&repo.join("src/a.ts"), "export const a = 3;\n");
    write_lf(&repo.join("src/new.ts"), "export const n = 1;\n");
    fs::remove_file(repo.join("src/del.ts")).unwrap();
    write_lf(&repo.join("src/b.ts"), "export const b = 99;\n");

    let r_part = ".b3/ship/verify/part.verify";
    let r_part_all = ".b3/ship/verify/part-all.verify";
    let r_part_ign = ".b3/ship/verify/part-ign.verify";
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            r_str,
            "--verify-cmd",
            "echo part",
            "--receipt-path",
            r_part,
            "--relevant-paths",
            "src/a.ts,src/new.ts,src/del.ts"
        ])
        .0,
        0
    );
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            r_str,
            "--verify-cmd",
            "echo all",
            "--receipt-path",
            r_part_all
        ])
        .0,
        0
    );
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            r_str,
            "--verify-cmd",
            "echo ign",
            "--receipt-path",
            r_part_ign,
            "--ignore-dirty-paths",
            "src/b.ts"
        ])
        .0,
        0
    );

    git_in(&repo, &["add", "src/a.ts", "src/new.ts"]);
    let (p1, _, p1_err) = run_b3(&[
        "guard",
        "precommit",
        "--repo-root",
        r_str,
        "--allowed-paths",
        "src/a.ts,src/new.ts,src/del.ts",
        "--require-verify-receipt",
        r_part,
    ]);
    assert_eq!(p1, 1);
    assert!(
        p1_err.contains("unstaged changes in receipt scope") && p1_err.contains("src/del.ts"),
        "{p1_err}"
    );

    git_in(&repo, &["add", "-u", "src/del.ts"]);
    assert_eq!(
        run_b3(&[
            "guard",
            "precommit",
            "--repo-root",
            r_str,
            "--allowed-paths",
            "src/a.ts,src/new.ts,src/del.ts",
            "--require-verify-receipt",
            r_part
        ])
        .0,
        0
    );

    // ALL receipt blocks dirty src/b.ts; IgnoreDirtyPaths mismatch -> VERIFY_STALE
    let (pa_c, _, pa_err) = run_b3(&[
        "guard",
        "precommit",
        "--repo-root",
        r_str,
        "--allowed-paths",
        "src/a.ts,src/new.ts,src/del.ts",
        "--require-verify-receipt",
        r_part_all,
    ]);
    assert_eq!(pa_c, 1);
    assert!(pa_err.contains("src/b.ts"), "{pa_err}");

    let (pm_c, _, pm_err) = run_b3(&[
        "guard",
        "precommit",
        "--repo-root",
        r_str,
        "--allowed-paths",
        "src/a.ts,src/new.ts,src/del.ts",
        "--require-verify-receipt",
        r_part_all,
        "--ignore-dirty-paths",
        "src/b.ts",
    ]);
    assert_eq!(pm_c, 1);
    assert!(pm_err.contains("VERIFY_STALE:"), "{pm_err}");

    assert_eq!(
        run_b3(&[
            "guard",
            "precommit",
            "--repo-root",
            r_str,
            "--allowed-paths",
            "src/a.ts,src/new.ts,src/del.ts",
            "--require-verify-receipt",
            r_part_ign,
            "--ignore-dirty-paths",
            "src/b.ts"
        ])
        .0,
        0
    );

    // Staging an ignored path MUST block even when AllowedPaths covers it
    git_in(&repo, &["add", "src/b.ts"]);
    let (si_c, _, si_err) = run_b3(&[
        "guard",
        "precommit",
        "--repo-root",
        r_str,
        "--allowed-paths",
        "src/a.ts,src/b.ts,src/new.ts,src/del.ts",
        "--require-verify-receipt",
        r_part_ign,
        "--ignore-dirty-paths",
        "src/b.ts",
    ]);
    assert_eq!(si_c, 1);
    assert!(
        si_err.contains("staged path excluded by ignore-dirty-paths")
            && si_err.contains("src/b.ts"),
        "{si_err}"
    );
    git_in(&repo, &["reset", "-q", "HEAD", "src/b.ts"]);

    // git rm --cached while WT still exists fails precommit
    git_in(&repo, &["rm", "-q", "--cached", "src/c.ts"]);
    let (rmc_c, _, rmc_err) = run_b3(&[
        "guard",
        "precommit",
        "--repo-root",
        r_str,
        "--allowed-paths",
        "src/a.ts,src/c.ts,src/new.ts,src/del.ts",
        "--require-verify-receipt",
        r_part,
    ]);
    assert_eq!(rmc_c, 1);
    assert!(
        rmc_err.contains("staged content differs from working tree"),
        "{rmc_err}"
    );
    git_in(&repo, &["reset", "-q", "HEAD"]);
    git_in(&repo, &["checkout", "--", "src"]);
    let _ = fs::remove_file(repo.join("src/new.ts"));

    // 4. C-01 secret path + glob *,.* + exact allow + MERGE_HEAD block
    write_lf(&repo.join(".env"), "SECRET=1\n");
    write_lf(&repo.join("src/a.ts"), "export const a = 4;\n");
    git_in(&repo, &["add", ".env", "src/a.ts"]);

    let (g1, _, g1_err) = run_b3(&[
        "guard",
        "precommit",
        "--repo-root",
        r_str,
        "--allowed-paths",
        "*,.*",
    ]);
    assert_eq!(g1, 1);
    assert!(g1_err.contains("invalid glob in path '*'"), "{g1_err}");

    let (g2, _, g2_err) = run_b3(&[
        "guard",
        "precommit",
        "--repo-root",
        r_str,
        "--allowed-paths",
        ".",
    ]);
    assert_eq!(g2, 1);
    assert!(
        g2_err.contains("secret path staged without exact allow"),
        "{g2_err}"
    );

    git_in(&repo, &["reset", "-q", "HEAD", ".env", "src/a.ts"]);
    git_in(&repo, &["add", ".env"]);
    let (g3, g3_out, _) = run_b3(&[
        "guard",
        "precommit",
        "--repo-root",
        r_str,
        "--allowed-paths",
        ".env",
    ]);
    assert_eq!(g3, 0);
    assert_eq!(g3_out, "PRECOMMIT_OK");
    git_in(&repo, &["reset", "-q", "HEAD", ".env"]);
    fs::remove_file(repo.join(".env")).unwrap();

    // .env.example is NOT a secret path
    write_lf(&repo.join("config/.env.example"), "TOKEN=v2\n");
    git_in(&repo, &["add", "config/.env.example"]);
    assert_eq!(
        run_b3(&[
            "guard",
            "precommit",
            "--repo-root",
            r_str,
            "--allowed-paths",
            "config"
        ])
        .0,
        0
    );

    write_lf(&repo.join(".git/MERGE_HEAD"), &format!("{base}\n"));
    let (mh_c, _, mh_err) = run_b3(&[
        "guard",
        "precommit",
        "--repo-root",
        r_str,
        "--allowed-paths",
        "config",
    ]);
    assert_eq!(mh_c, 1);
    assert!(
        mh_err.contains("git operation in progress (MERGE_HEAD)"),
        "{mh_err}"
    );
    fs::remove_file(repo.join(".git/MERGE_HEAD")).unwrap();
    git_in(&repo, &["reset", "-q", "HEAD"]);
    git_in(&repo, &["checkout", "--", "."]);

    // 5. SEC-01 bracketed [id]/page.tsx, Unicode café.ts, tài liệu [1] spaced.md, leading space
    write_lf(
        &repo.join("src/[id]/page.tsx"),
        "export const Page = () => 2;\n",
    );
    write_lf(&repo.join("src/café.ts"), "export const cafe = 2;\n");
    write_lf(&repo.join("docs/tài liệu [1] spaced.md"), "uni2\n");
    write_lf(&repo.join("docs/ lead.md"), "lead2\n");

    let r_lit = ".b3/ship/verify/lit.verify";
    let rel_lit = "src/[id]/page.tsx,src/café.ts,docs/tài liệu [1] spaced.md,docs/ lead.md";
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            r_str,
            "--verify-cmd",
            "echo lit",
            "--receipt-path",
            r_lit,
            "--relevant-paths",
            rel_lit
        ])
        .0,
        0
    );
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-check",
            "--repo-root",
            r_str,
            "--receipt-path",
            r_lit
        ])
        .0,
        0
    );
    git_in(
        &repo,
        &[
            "add",
            "src/[id]/page.tsx",
            "src/café.ts",
            "docs/tài liệu [1] spaced.md",
            "docs/ lead.md",
        ],
    );
    assert_eq!(
        run_b3(&[
            "guard",
            "precommit",
            "--repo-root",
            r_str,
            "--allowed-paths",
            rel_lit,
            "--require-verify-receipt",
            r_lit
        ])
        .0,
        0
    );
    write_lf(
        &repo.join("src/[id]/page.tsx"),
        "export const Page = () => 999;\n",
    );
    let (lit_st, _, lit_err) = run_b3(&[
        "guard",
        "verify-check",
        "--repo-root",
        r_str,
        "--receipt-path",
        r_lit,
    ]);
    assert_eq!(lit_st, 2);
    assert!(lit_err.contains("VERIFY_STALE:"), "{lit_err}");

    // 6. core.autocrlf=true stderr isolation
    let crlf_repo = tmp.path.join("crlf-repo");
    init_fresh_git_repo(&crlf_repo);
    git_in(&crlf_repo, &["config", "core.autocrlf", "true"]);
    fs::create_dir_all(crlf_repo.join("src")).unwrap();
    fs::write(crlf_repo.join("src/a.ts"), b"export const x = 1;\r\n").unwrap();
    git_in(&crlf_repo, &["add", "."]);
    git_in(&crlf_repo, &["commit", "-qm", "crlf init"]);
    fs::write(
        crlf_repo.join("src/a.ts"),
        b"export const x = 2;\nexport function hello(): number { return x; }\n",
    )
    .unwrap();
    let crlf_str = crlf_repo.to_str().unwrap();
    let (cv_c, cv_out, cv_err) = run_b3(&[
        "guard",
        "verify-run",
        "--repo-root",
        crlf_str,
        "--verify-cmd",
        "echo stderr-ok",
        "--receipt-path",
        ".b3/ship/verify/err.verify",
        "--relevant-paths",
        "src/a.ts",
    ]);
    assert_eq!(cv_c, 0, "{cv_out}\n{cv_err}");
    let err_rec_txt = fs::read_to_string(crlf_repo.join(".b3/ship/verify/err.verify")).unwrap();
    assert!(!err_rec_txt.contains("warning:"), "{err_rec_txt}");
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-check",
            "--repo-root",
            crlf_str,
            "--receipt-path",
            ".b3/ship/verify/err.verify"
        ])
        .0,
        0
    );
    git_in(&crlf_repo, &["add", "src/a.ts"]);
    assert_eq!(
        run_b3(&[
            "guard",
            "precommit",
            "--repo-root",
            crlf_str,
            "--allowed-paths",
            "src/a.ts",
            "--require-verify-receipt",
            ".b3/ship/verify/err.verify"
        ])
        .0,
        0
    );
    let (cds_c, cds_out, _) = run_b3(&["guard", "diff-scope", "--repo-root", crlf_str]);
    assert_eq!(cds_c, 0);
    assert!(!cds_out.contains("warning:"));
}

#[test]
fn receipt_mode_type_and_submodule_invariants() {
    let tmp = TempDirGuard::new("guard-mode-sub");
    let sub_origin = tmp.path.join("sub-origin");
    init_fresh_git_repo(&sub_origin);
    write_lf(&sub_origin.join("s.txt"), "sub-v1\n");
    git_in(&sub_origin, &["add", "s.txt"]);
    git_in(&sub_origin, &["commit", "-qm", "sub-v1"]);
    let sub1 = git_in(&sub_origin, &["rev-parse", "HEAD"]);
    write_lf(&sub_origin.join("s.txt"), "sub-v2\n");
    git_in(&sub_origin, &["add", "s.txt"]);
    git_in(&sub_origin, &["commit", "-qm", "sub-v2"]);
    let sub2 = git_in(&sub_origin, &["rev-parse", "HEAD"]);

    let repo = tmp.path.join("mt-repo");
    init_fresh_git_repo(&repo);
    write_lf(&repo.join("scripts/run.sh"), "#!/bin/sh\necho run\n");
    write_lf(&repo.join("other.txt"), "other\n");
    write_lf(&repo.join("unrelated.txt"), "unrelated-0\n");
    git_in(&repo, &["add", "."]);
    git_in(&repo, &["commit", "-qm", "init"]);
    let r_str = repo.to_str().unwrap();

    // 1. chmod +x / -x + core.filemode=true untracked script
    git_in(&repo, &["config", "core.filemode", "false"]);
    let r_chmod = ".b3/ship/verify/chmod.verify";
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            r_str,
            "--verify-cmd",
            "echo m0",
            "--receipt-path",
            r_chmod,
            "--relevant-paths",
            "scripts/run.sh"
        ])
        .0,
        0
    );
    git_in(&repo, &["update-index", "--chmod=+x", "scripts/run.sh"]);
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-check",
            "--repo-root",
            r_str,
            "--receipt-path",
            r_chmod
        ])
        .0,
        2
    );
    assert_eq!(
        run_b3(&[
            "guard",
            "precommit",
            "--repo-root",
            r_str,
            "--allowed-paths",
            "scripts/run.sh",
            "--require-verify-receipt",
            r_chmod
        ])
        .0,
        1
    );
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            r_str,
            "--verify-cmd",
            "echo m1",
            "--receipt-path",
            r_chmod,
            "--relevant-paths",
            "scripts/run.sh"
        ])
        .0,
        0
    );
    assert_eq!(
        run_b3(&[
            "guard",
            "precommit",
            "--repo-root",
            r_str,
            "--allowed-paths",
            "scripts/run.sh",
            "--require-verify-receipt",
            r_chmod
        ])
        .0,
        0
    );
    git_in(&repo, &["commit", "-qm", "chmod-x"]);
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-check",
            "--repo-root",
            r_str,
            "--receipt-path",
            r_chmod
        ])
        .0,
        0
    );

    git_in(&repo, &["config", "core.filemode", "true"]);
    git_in(&repo, &["update-index", "--chmod=-x", "scripts/run.sh"]);
    git_in(&repo, &["commit", "-qm", "chmod-644"]);
    let r_idxm = ".b3/ship/verify/idx-mode.verify";
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            r_str,
            "--verify-cmd",
            "echo idxm",
            "--receipt-path",
            r_idxm,
            "--relevant-paths",
            "scripts/run.sh"
        ])
        .0,
        0
    );
    git_in(&repo, &["update-index", "--chmod=+x", "scripts/run.sh"]);
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-check",
            "--repo-root",
            r_str,
            "--receipt-path",
            r_idxm
        ])
        .0,
        2
    );
    git_in(&repo, &["reset", "-q", "HEAD", "scripts/run.sh"]);
    write_lf(&repo.join("scripts/untr.sh"), "#!/bin/sh\necho u\n");
    let r_ufm = ".b3/ship/verify/untr-fm.verify";
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            r_str,
            "--verify-cmd",
            "echo ufm",
            "--receipt-path",
            r_ufm
        ])
        .0,
        0
    );
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-check",
            "--repo-root",
            r_str,
            "--receipt-path",
            r_ufm
        ])
        .0,
        0
    );
    fs::remove_file(repo.join("scripts/untr.sh")).unwrap();
    git_in(&repo, &["config", "core.filemode", "false"]);
    git_in(&repo, &["config", "core.symlinks", "false"]);

    // 2. 120000 <-> 100644 index mode transition keeping identical bytes ('scripts/run.sh')
    write_lf(&repo.join("lnk"), "scripts/run.sh");
    let lnk_sha = git_in(&repo, &["hash-object", "-w", "--", "lnk"]);
    git_in(
        &repo,
        &[
            "update-index",
            "--add",
            "--cacheinfo",
            &format!("120000,{lnk_sha},lnk"),
        ],
    );
    let r_sym = ".b3/ship/verify/sym.verify";
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            r_str,
            "--verify-cmd",
            "echo s0",
            "--receipt-path",
            r_sym,
            "--relevant-paths",
            "lnk"
        ])
        .0,
        0
    );
    assert_eq!(
        run_b3(&[
            "guard",
            "precommit",
            "--repo-root",
            r_str,
            "--allowed-paths",
            "lnk",
            "--require-verify-receipt",
            r_sym
        ])
        .0,
        0
    );
    git_in(&repo, &["commit", "-qm", "add-lnk"]);
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-check",
            "--repo-root",
            r_str,
            "--receipt-path",
            r_sym
        ])
        .0,
        0
    );

    // 120000 -> 100644 keeping identical bytes -> MUST go VERIFY_STALE + block precommit
    git_in(&repo, &["update-index", "--force-remove", "lnk"]);
    write_lf(&repo.join("lnk"), "scripts/run.sh");
    git_in(&repo, &["add", "lnk"]);
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-check",
            "--repo-root",
            r_str,
            "--receipt-path",
            r_sym
        ])
        .0,
        2
    );
    assert_eq!(
        run_b3(&[
            "guard",
            "precommit",
            "--repo-root",
            r_str,
            "--allowed-paths",
            "lnk",
            "--require-verify-receipt",
            r_sym
        ])
        .0,
        1
    );
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            r_str,
            "--verify-cmd",
            "echo s1",
            "--receipt-path",
            r_sym,
            "--relevant-paths",
            "lnk"
        ])
        .0,
        0
    );
    git_in(&repo, &["commit", "-qm", "lnk-to-file"]);
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-check",
            "--repo-root",
            r_str,
            "--receipt-path",
            r_sym
        ])
        .0,
        0
    );

    // 100644 -> 120000 + target edit invalidates receipt
    git_in(&repo, &["update-index", "--force-remove", "lnk"]);
    git_in(
        &repo,
        &[
            "update-index",
            "--add",
            "--cacheinfo",
            &format!("120000,{lnk_sha},lnk"),
        ],
    );
    git_in(&repo, &["commit", "-qm", "file-to-lnk"]);
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            r_str,
            "--verify-cmd",
            "echo s2",
            "--receipt-path",
            r_sym,
            "--relevant-paths",
            "lnk"
        ])
        .0,
        0
    );
    write_lf(&repo.join("lnk"), "other.txt");
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-check",
            "--repo-root",
            r_str,
            "--receipt-path",
            r_sym
        ])
        .0,
        2
    );
    write_lf(&repo.join("lnk"), "scripts/run.sh");

    // 3. Submodule 160000 gitlink updates + dirty submodule + untracked + nested repo + uninit 160000
    git_in(
        &repo,
        &[
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "add",
            "-q",
            sub_origin.to_str().unwrap(),
            "deps/sub",
        ],
    );
    git_in(&repo.join("deps/sub"), &["checkout", "-q", &sub1]);
    git_in(&repo, &["add", ".gitmodules", "deps/sub"]);
    git_in(&repo, &["commit", "-qm", "add-sub1"]);

    let r_sub_all = ".b3/ship/verify/sub-all.verify";
    let r_sub_sc = ".b3/ship/verify/sub-sc.verify";
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            r_str,
            "--verify-cmd",
            "echo sub-all",
            "--receipt-path",
            r_sub_all
        ])
        .0,
        0
    );
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            r_str,
            "--verify-cmd",
            "echo sub-sc",
            "--receipt-path",
            r_sub_sc,
            "--relevant-paths",
            "deps/sub"
        ])
        .0,
        0
    );

    // Move submodule pointer unstaged -> both ALL and scoped become VERIFY_STALE
    git_in(&repo.join("deps/sub"), &["checkout", "-q", &sub2]);
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-check",
            "--repo-root",
            r_str,
            "--receipt-path",
            r_sub_all
        ])
        .0,
        2
    );
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-check",
            "--repo-root",
            r_str,
            "--receipt-path",
            r_sub_sc
        ])
        .0,
        2
    );

    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            r_str,
            "--verify-cmd",
            "echo sub-mv",
            "--receipt-path",
            r_sub_sc,
            "--relevant-paths",
            "deps/sub"
        ])
        .0,
        0
    );
    // Unstaged submodule move blocks precommit; staging deps/sub passes; committing keeps VERIFY_VALID
    write_lf(&repo.join("other.txt"), "other-pair\n");
    git_in(&repo, &["add", "other.txt"]);
    let r_pair = ".b3/ship/verify/sub-pair.verify";
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            r_str,
            "--verify-cmd",
            "echo sub-pair",
            "--receipt-path",
            r_pair,
            "--relevant-paths",
            "deps/sub,other.txt"
        ])
        .0,
        0
    );
    assert_eq!(
        run_b3(&[
            "guard",
            "precommit",
            "--repo-root",
            r_str,
            "--allowed-paths",
            "deps/sub,other.txt",
            "--require-verify-receipt",
            r_pair
        ])
        .0,
        1
    );
    git_in(&repo, &["reset", "-q", "HEAD", "other.txt"]);
    git_in(&repo, &["checkout", "--", "other.txt"]);

    git_in(&repo, &["add", "deps/sub"]);
    assert_eq!(
        run_b3(&[
            "guard",
            "precommit",
            "--repo-root",
            r_str,
            "--allowed-paths",
            "deps/sub",
            "--require-verify-receipt",
            r_sub_sc
        ])
        .0,
        0
    );
    git_in(&repo, &["commit", "-qm", "bump-sub2"]);
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-check",
            "--repo-root",
            r_str,
            "--receipt-path",
            r_sub_sc
        ])
        .0,
        0
    );

    // Dirty tracked + untracked + nested repo inside submodule
    write_lf(&repo.join("deps/sub/s.txt"), "dirty-1\n");
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-check",
            "--repo-root",
            r_str,
            "--receipt-path",
            r_sub_sc
        ])
        .0,
        2
    );
    git_in(&repo.join("deps/sub"), &["checkout", "-q", "--", "s.txt"]);
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            r_str,
            "--verify-cmd",
            "echo sub-clean",
            "--receipt-path",
            r_sub_sc,
            "--relevant-paths",
            "deps/sub"
        ])
        .0,
        0
    );
    write_lf(&repo.join("deps/sub/sub-untr.txt"), "u1\n");
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-check",
            "--repo-root",
            r_str,
            "--receipt-path",
            r_sub_sc
        ])
        .0,
        2
    );
    fs::remove_file(repo.join("deps/sub/sub-untr.txt")).unwrap();

    let nested = repo.join("deps/sub/inner-nested");
    init_fresh_git_repo(&nested);
    write_lf(&nested.join("i.txt"), "in-dirty\n");
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            r_str,
            "--verify-cmd",
            "echo nested",
            "--receipt-path",
            r_sub_sc,
            "--relevant-paths",
            "deps/sub"
        ])
        .0,
        0
    );
    write_lf(&nested.join("i.txt"), "in-dirty-2\n");
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-check",
            "--repo-root",
            r_str,
            "--receipt-path",
            r_sub_sc
        ])
        .0,
        2
    );
    b3::fs::remove_dir_tree_safely(&nested).unwrap();

    // Uninitialized submodule (160000 gitlink in HEAD, empty dir on disk)
    fs::create_dir_all(repo.join("deps/uninit")).unwrap();
    git_in(
        &repo,
        &[
            "update-index",
            "--add",
            "--cacheinfo",
            &format!("160000,{sub1},deps/uninit"),
        ],
    );
    git_in(&repo, &["commit", "-qm", "add-uninit-sub"]);
    let r_uninit = ".b3/ship/verify/sub-uninit.verify";
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            r_str,
            "--verify-cmd",
            "echo sub-uninit",
            "--receipt-path",
            r_uninit,
            "--relevant-paths",
            "deps/uninit"
        ])
        .0,
        0
    );
    git_in(
        &repo,
        &[
            "update-index",
            "--cacheinfo",
            &format!("160000,{sub2},deps/uninit"),
        ],
    );
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-check",
            "--repo-root",
            r_str,
            "--receipt-path",
            r_uninit
        ])
        .0,
        2
    );
}

#[test]
fn mechanical_symbol_and_prune_safety() {
    let tmp = TempDirGuard::new("guard-mech-sym-prune");

    // 1. SEC-03 staged-only DROP TABLE + deleted .env + 10-file move + Obsoletes + AllowMassDelete
    let repo = tmp.path.join("mech-repo");
    clone_seeded_git_repo(&repo);
    write_lf(&repo.join("secret/.env"), "SECRET=1\n");
    write_lf(&repo.join("src/db.ts"), "export const q = 'SELECT 1';\n");
    write_lf(
        &repo.join("src/a.ts"),
        "export function movedFn() { return 1; }\n",
    );
    write_lf(&repo.join("src/b.ts"), "export const b = 1;\n");
    write_lf(
        &repo.join("src/lib.ts"),
        "export function droppedFn() { return 2; }\n",
    );
    write_lf(
        &repo.join("src/caller.ts"),
        "import { movedFn } from './a';\nimport { droppedFn } from './lib';\nexport const z = movedFn() + droppedFn();\n",
    );
    for i in 1..=10 {
        write_lf(
            &repo.join(format!("m{i}.ts")),
            &format!("export const mv{i} = {i};\n"),
        );
    }
    git_in(&repo, &["add", "."]);
    git_in(&repo, &["commit", "-qm", "init"]);
    let base = git_in(&repo, &["rev-parse", "HEAD"]);
    let r_str = repo.to_str().unwrap();

    // SEC-03: staged DROP TABLE caught even when WT reverted to base
    let drop_sql = format!("DROP {} users;", "TABLE");
    write_lf(
        &repo.join("src/db.ts"),
        &format!("export const q = '{drop_sql}';\n"),
    );
    git_in(&repo, &["add", "src/db.ts"]);
    write_lf(&repo.join("src/db.ts"), "export const q = 'SELECT 1';\n");
    let (sec_c, sec_out, _) = run_b3(&[
        "guard",
        "mechanical-check",
        "--repo-root",
        r_str,
        "--base-sha",
        &base,
        "--allowed-paths",
        "src/db.ts",
    ]);
    assert_eq!(sec_c, 2);
    assert!(sec_out.contains("destructive_sql"), "{sec_out}");
    git_in(&repo, &["reset", "-q", "HEAD", "src/db.ts"]);

    // Test file destructive SQL exempt
    write_lf(
        &repo.join("tests/db.test.ts"),
        &format!("const sql = \"{drop_sql}\";\n"),
    );
    let (tc, tout, _) = run_b3(&[
        "guard",
        "mechanical-check",
        "--repo-root",
        r_str,
        "--base-sha",
        &base,
        "--allowed-paths",
        "tests/db.test.ts",
    ]);
    assert_eq!(tc, 0, "{tout}");
    fs::remove_file(repo.join("tests/db.test.ts")).unwrap();

    // Delete tracked .env + move 10 files -> NO secret_path or mass_delete false positive
    git_in(&repo, &["rm", "-q", "secret/.env"]);
    fs::create_dir_all(repo.join("moved")).unwrap();
    for i in 1..=10 {
        fs::rename(
            repo.join(format!("m{i}.ts")),
            repo.join(format!("moved/m{i}.ts")),
        )
        .unwrap();
    }
    let (mv_c, mv_out, _) = run_b3(&[
        "guard",
        "mechanical-check",
        "--repo-root",
        r_str,
        "--base-sha",
        &base,
    ]);
    assert_eq!(mv_c, 0, "move/delete-env false positive: {mv_out}");
    git_in(&repo, &["reset", "-q", "HEAD", "secret/.env"]);
    git_in(&repo, &["checkout", "--", "secret/.env"]);

    // Obsoletes detects token in untracked file
    write_lf(
        &repo.join("src/new_obs.ts"),
        "const legacy = 'OLD_TOK_XYZ';\n",
    );
    let (oc, oout, _) = run_b3(&[
        "guard",
        "mechanical-check",
        "--repo-root",
        r_str,
        "--base-sha",
        &base,
        "--obsoletes",
        "OLD_TOK_XYZ",
    ]);
    assert_eq!(oc, 2);
    assert!(oout.contains("obsolete_hits=OLD_TOK_XYZ(1f)"), "{oout}");
    fs::remove_file(repo.join("src/new_obs.ts")).unwrap();

    // Real 10-file delete triggers mass_delete:10f, suppressed by --allow-mass-delete
    for i in 1..=10 {
        fs::remove_file(repo.join(format!("moved/m{i}.ts"))).unwrap();
    }
    let (md_c, md_out, _) = run_b3(&[
        "guard",
        "mechanical-check",
        "--repo-root",
        r_str,
        "--base-sha",
        &base,
    ]);
    assert_eq!(md_c, 2);
    assert!(md_out.contains("mass_delete:10f"), "{md_out}");
    let (md_ok_c, md_ok_out, _) = run_b3(&[
        "guard",
        "mechanical-check",
        "--repo-root",
        r_str,
        "--base-sha",
        &base,
        "--allow-mass-delete",
    ]);
    assert_eq!(md_ok_c, 0, "{md_ok_out}");

    // 2. symbol-check: batched export move passes; dropped export caught; orphan_internal vs publicApi
    write_lf(&repo.join("src/a.ts"), "export const aOnly = 0;\n");
    write_lf(
        &repo.join("src/b.ts"),
        "export const b = 1;\nexport function movedFn() { return 1; }\n",
    );
    write_lf(
        &repo.join("src/caller.ts"),
        "import { movedFn } from './b';\nimport { droppedFn } from './lib';\nexport const z = movedFn() + droppedFn();\n",
    );
    let (sm_c, sm_out, _) = run_b3(&[
        "guard",
        "symbol-check",
        "--repo-root",
        r_str,
        "--base-sha",
        &base,
    ]);
    assert_eq!(sm_c, 0, "batched export move should pass: {sm_out}");

    write_lf(
        &repo.join("src/lib.ts"),
        "function droppedFn() { return 2; }\nfunction internalDead() { return 3; }\nexport function publicApi() { return 4; }\n",
    );
    let (sd_c, sd_out, _) = run_b3(&[
        "guard",
        "symbol-check",
        "--repo-root",
        r_str,
        "--base-sha",
        &base,
    ]);
    assert_eq!(sd_c, 2);
    assert!(sd_out.contains("exported_removed=droppedFn"), "{sd_out}");
    assert!(sd_out.contains("dangling_refs=droppedFn(1f)"), "{sd_out}");
    assert!(
        sd_out.contains("orphan_internal=src/lib.ts:internalDead"),
        "{sd_out}"
    );
    assert!(!sd_out.contains("publicApi"), "{sd_out}");

    // 3. TargetRef branch literally named 'src' colliding with 'src/' dir + flag injection
    git_in(&repo, &["reset", "-q", "--hard", "HEAD"]);
    git_in(&repo, &["checkout", "-qb", "src"]);
    write_lf(&repo.join("src/pr-only.ts"), "export const pr = 1;\n");
    git_in(&repo, &["add", "src/pr-only.ts"]);
    git_in(&repo, &["commit", "-qm", "branch src"]);
    git_in(&repo, &["checkout", "-q", "main"]);
    let (tr_c, tr_out, _) = run_b3(&[
        "guard",
        "diff-scope",
        "--repo-root",
        r_str,
        "--target-ref",
        "src",
    ]);
    assert_eq!(tr_c, 0, "{tr_out}");
    assert!(tr_out.contains("review_files=src/pr-only.ts"), "{tr_out}");
    let (fi_c, _, fi_err) = run_b3(&[
        "guard",
        "diff-scope",
        "--repo-root",
        r_str,
        "--target-ref",
        "--bad-flag",
    ]);
    assert_eq!(fi_c, 1);
    assert!(fi_err.contains("DIFF_SCOPE_FAIL"), "{fi_err}");

    // 4. Prune safety: nested junction + runs-dir junction + default keep=10 PASS + autodev retired fallback (still staged-blocked)
    let decoy_nested = tmp.path.join("decoy-nested");
    let decoy_top = tmp.path.join("decoy-top");
    let decoy_runs = tmp.path.join("decoy-runs");
    write_lf(&decoy_nested.join("keep1.txt"), "keep1\n");
    write_lf(&decoy_top.join("keep2.txt"), "keep2\n");
    write_lf(&decoy_top.join("progress.md"), "- run_status: PASS\n");
    write_lf(&decoy_runs.join("keep3.txt"), "keep3\n");

    let pr_repo = tmp.path.join("prune-repo");
    fs::create_dir_all(&pr_repo).unwrap();
    let pr_str = pr_repo.to_str().unwrap();
    let (_, p_nest, _) = run_b3(&[
        "guard",
        "new-run",
        "--repo-root",
        pr_str,
        "--slug",
        "nested-pass",
        "--timestamp",
        "20261122-0001",
    ]);
    let (_, p_cur, _) = run_b3(&[
        "guard",
        "new-run",
        "--repo-root",
        pr_str,
        "--slug",
        "current-active",
        "--timestamp",
        "20261122-0003",
    ]);
    write_lf(
        &pr_repo.join(format!(".b3/ship/runs/{}/progress.md", p_nest.trim())),
        "- run_status: PASS\n",
    );
    write_lf(
        &pr_repo.join(format!(".b3/ship/runs/{}/progress.md", p_cur.trim())),
        "- run_status: running\n",
    );
    let nest_junc = pr_repo.join(format!(".b3/ship/runs/{}/nested-junc", p_nest.trim()));
    let top_junc = pr_repo.join(".b3/ship/runs/20261122-0002-top-junc");
    create_dir_link(&nest_junc, &decoy_nested);
    create_dir_link(&top_junc, &decoy_top);

    let (pr_c, pr_out, pr_err) = run_b3(&["guard", "prune", "--repo-root", pr_str, "--keep", "0"]);
    assert_eq!(pr_c, 0, "{pr_out}\n{pr_err}");
    assert!(pr_out.contains("PRUNE_OK: 1 removed"), "{pr_out}");
    assert!(decoy_nested.join("keep1.txt").is_file());
    assert!(decoy_top.join("keep2.txt").is_file());
    remove_dir_link_only(&top_junc);

    // runs dir itself is a junction -> PRUNE_FAIL
    let pr_link_repo = tmp.path.join("prune-runs-link");
    fs::create_dir_all(pr_link_repo.join(".b3/ship")).unwrap();
    let runs_junc = pr_link_repo.join(".b3/ship/runs");
    create_dir_link(&runs_junc, &decoy_runs);
    let (pl_c, _, pl_err) = run_b3(&[
        "guard",
        "prune",
        "--repo-root",
        pr_link_repo.to_str().unwrap(),
        "--keep",
        "0",
    ]);
    assert_eq!(pl_c, 1);
    assert!(
        pl_err.contains("PRUNE_FAIL: runs directory is a link"),
        "{pl_err}"
    );
    assert!(decoy_runs.join("keep3.txt").is_file());
    remove_dir_link_only(&runs_junc);

    // Default keep 10 PASS: create 12 PASS runs + 1 running; oldest 2 PASS pruned, newest 10 kept
    let k10_repo = tmp.path.join("keep10-repo");
    fs::create_dir_all(&k10_repo).unwrap();
    let k10_str = k10_repo.to_str().unwrap();
    for i in 1..=12 {
        let ts = format!("20261122-{i:04}");
        let (_, rid, _) = run_b3(&[
            "guard",
            "new-run",
            "--repo-root",
            k10_str,
            "--slug",
            "p",
            "--timestamp",
            &ts,
        ]);
        write_lf(
            &k10_repo.join(format!(".b3/ship/runs/{}/progress.md", rid.trim())),
            "- run_status: PASS\n",
        );
    }
    let (_, active_id, _) = run_b3(&[
        "guard",
        "new-run",
        "--repo-root",
        k10_str,
        "--slug",
        "active",
        "--timestamp",
        "20261122-0099",
    ]);
    write_lf(
        &k10_repo.join(format!(".b3/ship/runs/{}/progress.md", active_id.trim())),
        "- run_status: running\n",
    );
    let (k10_c, k10_out, _) = run_b3(&["guard", "prune", "--repo-root", k10_str]);
    assert_eq!(k10_c, 0);
    assert!(k10_out.contains("PRUNE_OK: 2 removed"), "{k10_out}");
    assert!(!k10_repo.join(".b3/ship/runs/20261122-0001-p").exists());
    assert!(!k10_repo.join(".b3/ship/runs/20261122-0002-p").exists());
    assert!(k10_repo.join(".b3/ship/runs/20261122-0003-p").is_dir());
    assert!(k10_repo
        .join(format!(".b3/ship/runs/{}", active_id.trim()))
        .is_dir());

    // .b3/autodev fallback retired in runs.rs, but checkpoint staging guard still blocks it
    let ad_repo = tmp.path.join("autodev-repo");
    init_fresh_git_repo(&ad_repo);
    write_lf(
        &ad_repo.join(".b3/autodev/runs/20261121-0100-old/progress.md"),
        "- run_status: running\n",
    );
    write_lf(&ad_repo.join(".b3/autodev/CURRENT"), "20261121-0100-old\n");
    let ad_str = ad_repo.to_str().unwrap();
    let (adr_c, _, adr_err) = run_b3(&["guard", "resolve-run", "--repo-root", ad_str]);
    assert_eq!(adr_c, 1);
    assert!(adr_err.contains("NO_ACTIVE_RUN"), "{adr_err}");
    let (adl_c, adl_out, _) = run_b3(&["guard", "list-runs", "--repo-root", ad_str]);
    assert_eq!(adl_c, 0);
    assert_eq!(adl_out, "NO_RUNS");
    git_in(
        &ad_repo,
        &[
            "add",
            "-f",
            ".b3/autodev/runs/20261121-0100-old/progress.md",
        ],
    );
    let (adp_c, _, adp_err) = run_b3(&[
        "guard",
        "precommit",
        "--repo-root",
        ad_str,
        "--allowed-paths",
        "src/app.txt",
    ]);
    assert_eq!(adp_c, 1);
    assert!(adp_err.contains("checkpoint staged"), "{adp_err}");
}

#[test]
fn wave_attribution_and_worktree_isolation() {
    let tmp = TempDirGuard::new("guard-wave-wt");
    let repo = tmp.path.join("ai-repo");
    clone_seeded_git_repo(&repo);
    write_lf(&repo.join("api/a.ts"), "export const a = 1;\n");
    write_lf(&repo.join("ui/b.tsx"), "export const B = () => null;\n");
    write_lf(&repo.join("src/c.ts"), "export const c = 1;\n");
    write_lf(
        &repo.join("src/shared/types.ts"),
        "export type Id = string;\n",
    );
    write_lf(&repo.join("docs/scratch.md"), "# scratch\n");
    write_lf(&repo.join("docs/authority/pin.md"), "pin: v1\n");
    write_lf(&repo.join("config/lock.json"), "{\"v\":1}\n");
    git_in(&repo, &["add", "."]);
    git_in(&repo, &["commit", "-qm", "seed"]);
    let head = git_in(&repo, &["rev-parse", "HEAD"]);
    let r_str = repo.to_str().unwrap();

    // 1. check-wave concurrency bounds (omitted adaptive, 8, 64 ok; 65 & 0 rejected)
    let (c8, o8, _) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r_str,
        "--partition",
        "--max-concurrency",
        "8",
        "--wave-specs",
        "T1=api/a.ts;T2=ui/b.tsx",
    ]);
    assert_eq!(c8, 0);
    assert!(o8.contains("max_concurrency=8"), "{o8}");
    assert_eq!(
        run_b3(&[
            "guard",
            "check-wave",
            "--repo-root",
            r_str,
            "--partition",
            "--max-concurrency",
            "64",
            "--wave-specs",
            "T1=api/a.ts;T2=ui/b.tsx"
        ])
        .0,
        0
    );
    assert_eq!(
        run_b3(&[
            "guard",
            "check-wave",
            "--repo-root",
            r_str,
            "--partition",
            "--max-concurrency",
            "65",
            "--wave-specs",
            "T1=api/a.ts;T2=ui/b.tsx"
        ])
        .0,
        1
    );
    assert_eq!(
        run_b3(&[
            "guard",
            "check-wave",
            "--repo-root",
            r_str,
            "--partition",
            "--max-concurrency",
            "0",
            "--wave-specs",
            "T1=api/a.ts"
        ])
        .0,
        1
    );

    // 2. SHARED_READ_ONLY (TaskId=none / []) + mixed RW + '.' rejection + ProtectedPaths + CF-04 junction
    let (ro_c, ro_out, _) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r_str,
        "--partition",
        "--wave-specs",
        "U1=none;U2=[]",
        "--wave-reads",
        "U1=src/shared/types.ts,api/a.ts;U2=src/shared/types.ts,docs/guide.md",
        "--expected-base-sha",
        &head,
    ]);
    assert_eq!(ro_c, 0);
    assert!(
        ro_out.contains("WAVE_OK: disjoint (2 tasks, 0 paths)"),
        "{ro_out}"
    );

    assert_eq!(
        run_b3(&[
            "guard",
            "check-wave",
            "--repo-root",
            r_str,
            "--partition",
            "--wave-specs",
            "T1=.;T2=ui/b.tsx"
        ])
        .0,
        1
    );
    assert_eq!(
        run_b3(&[
            "guard",
            "check-wave",
            "--repo-root",
            r_str,
            "--partition",
            "--wave-specs",
            "T1=docs/authority/pin.md",
            "--protected-paths",
            "docs/authority"
        ])
        .0,
        1
    );
    assert_eq!(
        run_b3(&[
            "guard",
            "check-wave",
            "--repo-root",
            r_str,
            "--partition",
            "--wave-specs",
            "T1=None;T2=api/a.ts",
            "--wave-reads",
            "T2=None",
        ])
        .0,
        2
    );

    // --check-dirty-scope: user_only partial split vs unexpected_dirty
    write_lf(&repo.join("docs/scratch.md"), "# user dirty\n");
    let (ds_c, ds_out, _) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r_str,
        "--partition",
        "--check-dirty-scope",
        "--wave-specs",
        "T1=docs/scratch.md;T2=api/a.ts;T3=ui/b.tsx",
        "--ignore-dirty-paths",
        "docs/scratch.md",
        "--expected-base-sha",
        &head,
    ]);
    assert_eq!(ds_c, 0);
    assert!(ds_out.contains("blocked_tasks=T1"), "{ds_out}");
    assert!(
        ds_out
            .contains("WAVE_PARTITIONED: waves=1 max_parallel=2 reason=dirty_scope_partial_split"),
        "{ds_out}"
    );
    write_lf(&repo.join("src/stray.ts"), "export const s = 1;\n");
    let (unexp_c, unexp_out, _) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r_str,
        "--partition",
        "--check-dirty-scope",
        "--wave-specs",
        "T2=api/a.ts;T3=ui/b.tsx",
        "--ignore-dirty-paths",
        "docs/scratch.md",
        "--expected-base-sha",
        &head,
    ]);
    assert_eq!(unexp_c, 2);
    assert!(
        unexp_out.contains("WAVE_BASE_MISMATCH: unexpected_dirty(src/stray.ts)"),
        "{unexp_out}"
    );
    fs::remove_file(repo.join("src/stray.ts")).unwrap();

    // CF-04 unsafe reparse child rejection
    let child_junc = repo.join("src/junc_docs");
    create_dir_link(&child_junc, &repo.join("docs"));
    let (jc, _, jerr) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r_str,
        "--partition",
        "--wave-specs",
        "T1=src/junc_docs/guide.md",
    ]);
    assert_eq!(jc, 1);
    assert!(jerr.contains("unsafe symlink or junction alias"), "{jerr}");
    let (mjc, _, mjerr) = run_b3(&[
        "guard",
        "mechanical-check",
        "--repo-root",
        r_str,
        "--base-sha",
        &head,
        "--protected-paths",
        "src/junc_docs/guide.md",
    ]);
    assert_eq!(mjc, 1);
    assert!(
        mjerr.contains("unsafe symlink or junction alias"),
        "{mjerr}"
    );
    remove_dir_link_only(&child_junc);

    // 3. mechanical-check attribution + WorkerRoots + DirtyDigests WT & staged tamper
    let orig_scratch_sha = b3::fs::sha256_file_hex(&repo.join("docs/scratch.md")).unwrap();
    write_lf(&repo.join("api/a.ts"), "export const a = 20;\n");
    write_lf(&repo.join("ui/b.tsx"), "export const B = () => 'w2';\n");

    let (u_c, u_out, _) = run_b3(&[
        "guard",
        "mechanical-check",
        "--repo-root",
        r_str,
        "--base-sha",
        &head,
        "--allowed-paths",
        "api/a.ts,ui/b.tsx",
        "--ignore-dirty-paths",
        "docs/scratch.md",
        "--wave-specs",
        "T1=api/a.ts;T2=ui/b.tsx",
    ]);
    assert_eq!(u_c, 0);
    assert!(
        u_out.contains("ownership_verification=UNVERIFIED_COMBINED_ONLY"),
        "{u_out}"
    );

    let (ca_c, ca_out, _) = run_b3(&[
        "guard",
        "mechanical-check",
        "--repo-root",
        r_str,
        "--base-sha",
        &head,
        "--allowed-paths",
        "api/a.ts,ui/b.tsx",
        "--ignore-dirty-paths",
        "docs/scratch.md",
        "--wave-specs",
        "T1=api/a.ts;T2=ui/b.tsx",
        "--worker-changes",
        "T1=api/a.ts;T2=ui/b.tsx",
    ]);
    assert_eq!(ca_c, 0);
    assert!(
        ca_out.contains("ownership_verification=CALLER_ATTRIBUTED"),
        "{ca_out}"
    );

    git_in(&repo, &["checkout", "--", "ui/b.tsx"]);
    let (pa_c, pa_out, _) = run_b3(&[
        "guard",
        "mechanical-check",
        "--repo-root",
        r_str,
        "--base-sha",
        &head,
        "--allowed-paths",
        "api/a.ts,ui/b.tsx",
        "--ignore-dirty-paths",
        "docs/scratch.md",
        "--wave-specs",
        "T1=api/a.ts;T2=ui/b.tsx",
        "--worker-changes",
        "T1=api/a.ts",
    ]);
    assert_eq!(pa_c, 2);
    assert!(
        pa_out.contains("ownership_verification=PARTIAL_ATTRIBUTION"),
        "{pa_out}"
    );
    write_lf(&repo.join("ui/b.tsx"), "export const B = () => 'w2';\n");

    // VERIFIED_PER_WORKER via real linked worktrees + content_mismatch
    let wt1 = tmp.path.join("wt1");
    let wt2 = tmp.path.join("wt2");
    git_in(
        &repo,
        &[
            "worktree",
            "add",
            "-q",
            "-b",
            "b-wt1",
            wt1.to_str().unwrap(),
            &head,
        ],
    );
    git_in(
        &repo,
        &[
            "worktree",
            "add",
            "-q",
            "-b",
            "b-wt2",
            wt2.to_str().unwrap(),
            &head,
        ],
    );
    write_lf(&wt1.join("api/a.ts"), "export const a = 20;\n");
    write_lf(&wt2.join("ui/b.tsx"), "export const B = () => 'w2';\n");
    let wr_spec = format!("T1={};T2={}", wt1.display(), wt2.display());
    let (wr_c, wr_out, _) = run_b3(&[
        "guard",
        "mechanical-check",
        "--repo-root",
        r_str,
        "--base-sha",
        &head,
        "--allowed-paths",
        "api/a.ts,ui/b.tsx",
        "--ignore-dirty-paths",
        "docs/scratch.md",
        "--wave-specs",
        "T1=api/a.ts;T2=ui/b.tsx",
        "--worker-roots",
        &wr_spec,
    ]);
    assert_eq!(wr_c, 0, "{wr_out}");
    assert!(
        wr_out.contains("ownership_verification=VERIFIED_PER_WORKER"),
        "{wr_out}"
    );

    write_lf(&wt1.join("api/a.ts"), "export const a = 999;\n");
    let (wrm_c, wrm_out, _) = run_b3(&[
        "guard",
        "mechanical-check",
        "--repo-root",
        r_str,
        "--base-sha",
        &head,
        "--allowed-paths",
        "api/a.ts,ui/b.tsx",
        "--ignore-dirty-paths",
        "docs/scratch.md",
        "--wave-specs",
        "T1=api/a.ts;T2=ui/b.tsx",
        "--worker-roots",
        &wr_spec,
    ]);
    assert_eq!(wrm_c, 2);
    assert!(
        wrm_out.contains("api/a.ts(T1->content_mismatch)"),
        "{wrm_out}"
    );

    // DirtyDigests WT tamper and staged tamper
    let dd_spec = format!("docs/scratch.md={orig_scratch_sha}");
    assert_eq!(
        run_b3(&[
            "guard",
            "mechanical-check",
            "--repo-root",
            r_str,
            "--base-sha",
            &head,
            "--allowed-paths",
            "api/a.ts,ui/b.tsx",
            "--ignore-dirty-paths",
            "docs/scratch.md",
            "--dirty-digests",
            &dd_spec,
            "--wave-specs",
            "T1=api/a.ts;T2=ui/b.tsx",
            "--worker-changes",
            "T1=api/a.ts;T2=ui/b.tsx"
        ])
        .0,
        0
    );
    write_lf(&repo.join("docs/scratch.md"), "# tampered-wt\n");
    let (dt1_c, dt1_out, _) = run_b3(&[
        "guard",
        "mechanical-check",
        "--repo-root",
        r_str,
        "--base-sha",
        &head,
        "--allowed-paths",
        "api/a.ts,ui/b.tsx",
        "--ignore-dirty-paths",
        "docs/scratch.md",
        "--dirty-digests",
        &dd_spec,
        "--wave-specs",
        "T1=api/a.ts;T2=ui/b.tsx",
        "--worker-changes",
        "T1=api/a.ts;T2=ui/b.tsx",
    ]);
    assert_eq!(dt1_c, 2);
    assert!(
        dt1_out.contains("dirty_tamper=docs/scratch.md"),
        "{dt1_out}"
    );
    git_in(&repo, &["add", "docs/scratch.md"]);
    let (dt2_c, dt2_out, _) = run_b3(&[
        "guard",
        "mechanical-check",
        "--repo-root",
        r_str,
        "--base-sha",
        &head,
        "--allowed-paths",
        "api/a.ts,ui/b.tsx",
        "--ignore-dirty-paths",
        "docs/scratch.md",
        "--dirty-digests",
        &dd_spec,
        "--wave-specs",
        "T1=api/a.ts;T2=ui/b.tsx",
        "--worker-changes",
        "T1=api/a.ts;T2=ui/b.tsx",
    ]);
    assert_eq!(dt2_c, 2);
    assert!(
        dt2_out.contains("dirty_tamper=docs/scratch.md"),
        "{dt2_out}"
    );

    // 4. check-worktree: --require-isolated, --peer-roots, base_mismatch, 8.3 short paths, Unix $PWD/B3_LOGICAL_PWD
    let (wt_ok_c, wt_ok_out, _) = run_b3(&[
        "guard",
        "check-worktree",
        "--repo-root",
        wt1.to_str().unwrap(),
        "--expected-root",
        r_str,
        "--expected-base-sha",
        &head,
        "--peer-roots",
        wt2.to_str().unwrap(),
        "--require-isolated",
    ]);
    assert_eq!(wt_ok_c, 0, "{wt_ok_out}");
    assert!(
        wt_ok_out.contains("linked=true isolated=true"),
        "{wt_ok_out}"
    );

    let (wt_bm_c, _, wt_bm_err) = run_b3(&[
        "guard",
        "check-worktree",
        "--repo-root",
        wt1.to_str().unwrap(),
        "--expected-base-sha",
        &"0".repeat(40),
    ]);
    assert_eq!(wt_bm_c, 2);
    assert!(wt_bm_err.contains("base_mismatch"), "{wt_bm_err}");

    let (wt_reused_c, _, wt_reused_err) = run_b3(&[
        "guard",
        "check-worktree",
        "--repo-root",
        r_str,
        "--expected-root",
        r_str,
        "--require-isolated",
    ]);
    assert_eq!(wt_reused_c, 2);
    assert!(
        wt_reused_err.contains("parent_root_reused_or_nested"),
        "{wt_reused_err}"
    );

    let (wt_dup_c, _, wt_dup_err) = run_b3(&[
        "guard",
        "check-worktree",
        "--repo-root",
        wt1.to_str().unwrap(),
        "--peer-roots",
        wt1.to_str().unwrap(),
    ]);
    assert_eq!(wt_dup_c, 2);
    assert!(
        wt_dup_err.contains("duplicate_or_nested_worktree"),
        "{wt_dup_err}"
    );

    let other_repo = tmp.path.join("other-repo");
    clone_seeded_git_repo(&other_repo);
    let (wt_peer_mis_c, _, wt_peer_mis_err) = run_b3(&[
        "guard",
        "check-worktree",
        "--repo-root",
        wt1.to_str().unwrap(),
        "--peer-roots",
        other_repo.to_str().unwrap(),
    ]);
    assert_eq!(wt_peer_mis_c, 2);
    assert!(
        wt_peer_mis_err.contains("peer_repo_mismatch"),
        "{wt_peer_mis_err}"
    );

    #[cfg(windows)]
    {
        let long_repo = tmp.path.join("very_long_worktree_directory_name");
        clone_seeded_git_repo(&long_repo);
        let long_head = git_in(&long_repo, &["rev-parse", "HEAD"]);
        if let Some(short_p) = to_windows_short_path(&long_repo) {
            let (sc, sout, serr) = run_b3(&[
                "guard",
                "check-worktree",
                "--repo-root",
                short_p.to_str().unwrap(),
                "--expected-root",
                long_repo.to_str().unwrap(),
                "--expected-base-sha",
                &long_head,
            ]);
            assert_eq!(
                sc, 0,
                "8.3 short path check-worktree failed: {sout}\n{serr}"
            );
        }
    }

    #[cfg(unix)]
    {
        let sym_cwd = tmp.path.join("sym_cwd");
        std::os::unix::fs::symlink(&repo, &sym_cwd).unwrap();
        let (uc1, _, uerr1) = run_b3_env(
            &["guard", "check-worktree", "--repo-root", "."],
            Some(&repo),
            &[("PWD", sym_cwd.to_str().unwrap())],
            &["B3_LOGICAL_PWD"],
        );
        assert_eq!(uc1, 2);
        assert!(uerr1.contains("unsafe_reparse_root"), "{uerr1}");
        let (uc2, _, uerr2) = run_b3_env(
            &["guard", "check-worktree", "--repo-root", "."],
            Some(&repo),
            &[("B3_LOGICAL_PWD", sym_cwd.to_str().unwrap())],
            &[],
        );
        assert_eq!(uc2, 2);
        assert!(uerr2.contains("unsafe_reparse_root"), "{uerr2}");
    }

    git_in(&repo, &["worktree", "remove", "-f", wt1.to_str().unwrap()]);
    git_in(&repo, &["worktree", "remove", "-f", wt2.to_str().unwrap()]);
}

#[test]
fn context_cache_evidence_check_and_product_smoke() {
    let tmp = TempDirGuard::new("guard-ctx-ev-smoke");

    // 1. context-cache lifecycle, invalidation, and tamper rejection
    let repo = tmp.path.join("ctx-repo");
    clone_seeded_git_repo(&repo);
    let sub_origin = tmp.path.join("ctx-sub-origin");
    init_fresh_git_repo(&sub_origin);
    write_lf(&sub_origin.join("sub.ts"), "export const subVer = 1;\n");
    git_in(&sub_origin, &["add", "."]);
    git_in(&sub_origin, &["commit", "-qm", "sub"]);

    write_lf(
        &repo.join("src/contracts/order.ts"),
        "export interface Order { id: string; }\n",
    );
    write_lf(
        &repo.join("src/deps/auth.ts"),
        "export function verifyToken(t: string): boolean { return t.length > 0; }\n",
    );
    write_lf(
        &repo.join("src/orders/handler.ts"),
        "export function handleOrder(id: string): string { return id; }\n",
    );
    git_in(&repo, &["add", "."]);
    git_in(&repo, &["commit", "-qm", "ctx init"]);
    git_in(
        &repo,
        &[
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "add",
            "-q",
            sub_origin.to_str().unwrap(),
            "libs/sub",
        ],
    );
    git_in(&repo, &["commit", "-qm", "add sub"]);
    let head_a = git_in(&repo, &["rev-parse", "HEAD"]);
    let r_str = repo.to_str().unwrap();

    let sum_rel = ".b3/ship/ctx/sum.md";
    write_lf(&repo.join(sum_rel), "# Iter 1 Summary\n");
    let cache_rel = ".b3/ship/ctx/iter1.ctx";
    let (rc, rout, rerr) = run_b3(&[
        "guard",
        "context-cache",
        "--repo-root",
        r_str,
        "--action",
        "record",
        "--cache-path",
        cache_rel,
        "--scope-id",
        "rl-iter1",
        "--anchor-paths",
        "src/contracts/order.ts,src/deps/auth.ts",
        "--summary-ref",
        sum_rel,
        "--graph-index-sha",
        &head_a,
    ]);
    assert_eq!(rc, 0, "{rout}\n{rerr}");
    assert!(rout.contains("CONTEXT_RECORDED:"), "{rout}");

    let (fc, fout, _) = run_b3(&[
        "guard",
        "context-cache",
        "--repo-root",
        r_str,
        "--action",
        "check",
        "--cache-path",
        cache_rel,
        "--scope-id",
        "rl-iter1",
    ]);
    assert_eq!(fc, 0);
    assert!(
        fout.contains("CONTEXT_FRESH: scope=rl-iter1") && fout.contains("graph_index=FRESH"),
        "{fout}"
    );

    // H-03 staged anchor divergence while WT == HEAD
    write_lf(&repo.join("src/deps/auth.ts"), "BROKEN_STAGED_CONTENT\n");
    git_in(&repo, &["add", "src/deps/auth.ts"]);
    write_lf(
        &repo.join("src/deps/auth.ts"),
        "export function verifyToken(t: string): boolean { return t.length > 0; }\n",
    );
    let (st1, _, st1_err) = run_b3(&[
        "guard",
        "context-cache",
        "--repo-root",
        r_str,
        "--action",
        "check",
        "--cache-path",
        cache_rel,
        "--scope-id",
        "rl-iter1",
    ]);
    assert_eq!(st1, 2);
    assert!(st1_err.contains("reasons=anchor_changed"), "{st1_err}");
    git_in(&repo, &["reset", "-q", "HEAD", "src/deps/auth.ts"]);

    // Graph mismatch & dirty submodule with diff.ignoreSubmodules=all
    let (gm_c, _, gm_err) = run_b3(&[
        "guard",
        "context-cache",
        "--repo-root",
        r_str,
        "--action",
        "check",
        "--cache-path",
        cache_rel,
        "--scope-id",
        "rl-iter1",
        "--graph-index-sha",
        "none",
    ]);
    assert_eq!(gm_c, 2);
    assert!(gm_err.contains("reasons=graph_index_mismatch"), "{gm_err}");

    git_in(&repo, &["config", "diff.ignoreSubmodules", "all"]);
    write_lf(&repo.join("libs/sub/sub.ts"), "export const subVer = 2;\n");
    let (sm_c, _, sm_err) = run_b3(&[
        "guard",
        "context-cache",
        "--repo-root",
        r_str,
        "--action",
        "check",
        "--cache-path",
        cache_rel,
        "--scope-id",
        "rl-iter1",
    ]);
    assert_eq!(sm_c, 2);
    assert!(sm_err.contains("reasons=graph_index_stale"), "{sm_err}");
    git_in(&repo.join("libs/sub"), &["checkout", "--", "sub.ts"]);
    git_in(&repo, &["config", "--unset", "diff.ignoreSubmodules"]);

    // Summary tamper & missing summary & empty cache & hash tamper
    write_lf(&repo.join(sum_rel), "# Mutated\n");
    let (sum_c, _, sum_err) = run_b3(&[
        "guard",
        "context-cache",
        "--repo-root",
        r_str,
        "--action",
        "check",
        "--cache-path",
        cache_rel,
        "--scope-id",
        "rl-iter1",
    ]);
    assert_eq!(sum_c, 2);
    assert!(sum_err.contains("reasons=summary_changed"), "{sum_err}");
    fs::remove_file(repo.join(sum_rel)).unwrap();
    let (ms_c, _, ms_err) = run_b3(&[
        "guard",
        "context-cache",
        "--repo-root",
        r_str,
        "--action",
        "check",
        "--cache-path",
        cache_rel,
        "--scope-id",
        "rl-iter1",
    ]);
    assert_eq!(ms_c, 1);
    assert!(
        ms_err.contains("CONTEXT_CORRUPT: missing or invalid summary_ref"),
        "{ms_err}"
    );
    write_lf(&repo.join(sum_rel), "# Iter 1 Summary\n");

    let (ec_c, _, ec_err) = run_b3(&[
        "guard",
        "context-cache",
        "--repo-root",
        r_str,
        "--action",
        "record",
        "--cache-path",
        ".b3/ship/ctx/empty.ctx",
        "--scope-id",
        "sec-empty",
        "--anchor-paths",
        "none",
        "--graph-index-sha",
        "none",
    ]);
    assert_eq!(ec_c, 1);
    assert!(ec_err.contains("CONTEXT_ERROR: empty cache"), "{ec_err}");

    let tamper_rel = ".b3/ship/ctx/tamper.ctx";
    let valid_raw = fs::read_to_string(repo.join(cache_rel)).unwrap();
    fs::write(
        repo.join(tamper_rel),
        valid_raw.replace('\n', "\r\n").as_bytes(),
    )
    .unwrap();
    let (tc, _, terr) = run_b3(&[
        "guard",
        "context-cache",
        "--repo-root",
        r_str,
        "--action",
        "check",
        "--cache-path",
        tamper_rel,
    ]);
    assert_eq!(tc, 1);
    assert!(terr.contains("CONTEXT_CORRUPT:"), "{terr}");

    // Symlink/junction escape in context-cache
    let outside_ctx = tmp.path.join("outside-ctx");
    fs::create_dir_all(&outside_ctx).unwrap();
    let ctx_junc = repo.join(".b3/ship/linked-ctx");
    create_dir_link(&ctx_junc, &outside_ctx);
    let (jc, _, jerr) = run_b3(&[
        "guard",
        "context-cache",
        "--repo-root",
        r_str,
        "--action",
        "record",
        "--cache-path",
        ".b3/ship/linked-ctx/esc.ctx",
        "--scope-id",
        "esc",
        "--anchor-paths",
        "src/contracts/order.ts",
    ]);
    assert_eq!(jc, 1);
    assert!(jerr.contains("CONTEXT_ERROR: invalid cache_path"), "{jerr}");
    remove_dir_link_only(&ctx_junc);

    // 2. evidence-check: write-manifest, EVIDENCE_FRESH, EVIDENCE_STALE, tamper
    write_lf(&repo.join("sources/primary.md"), "# Primary\nClause A\n");
    let m_rel = ".b3/research-ship/runs/r1/evidence/sources.manifest";
    let (ew_c, ew_out, ew_err) = run_b3(&[
        "guard",
        "evidence-check",
        "--repo-root",
        r_str,
        "--write-manifest",
        "--manifest-path",
        m_rel,
        "--source-paths",
        "sources/primary.md",
    ]);
    assert_eq!(ew_c, 0, "{ew_out}\n{ew_err}");
    assert!(ew_out.contains("EVIDENCE_WRITTEN:"), "{ew_out}");
    assert_eq!(
        run_b3(&[
            "guard",
            "evidence-check",
            "--repo-root",
            r_str,
            "--manifest-path",
            m_rel,
            "--source-paths",
            "sources/primary.md"
        ])
        .0,
        0
    );
    write_lf(
        &repo.join("sources/primary.md"),
        "# Primary\nClause A edited\n",
    );
    let (es_c, _, es_err) = run_b3(&[
        "guard",
        "evidence-check",
        "--repo-root",
        r_str,
        "--manifest-path",
        m_rel,
    ]);
    assert_eq!(es_c, 2);
    assert!(es_err.contains("EVIDENCE_STALE:"), "{es_err}");
    write_lf(&repo.join(m_rel), "corrupt_manifest\n");
    assert_eq!(
        run_b3(&[
            "guard",
            "evidence-check",
            "--repo-root",
            r_str,
            "--manifest-path",
            m_rel
        ])
        .0,
        1
    );

    // 3. Smoke product lifecycle: b3 install product --host cursor + new-run + resolve-run + 2-task resume + verify-run + precommit
    let b3_home = common::repo_root();
    let product = tmp.path.join("product-smoke");
    init_fresh_git_repo(&product);
    let p_str = product.to_str().unwrap();
    let home_str = b3_home.to_str().unwrap();
    let models_iso = tmp.path.join("isolated-models.md");
    let (ic, iout, ierr) = run_b3_env(
        &[
            "install",
            "product",
            "--product-root",
            p_str,
            "--b3-home",
            home_str,
            "--host",
            "cursor",
        ],
        None,
        &[
            ("B3_SKIP_MODEL_INIT", "1"),
            ("B3_MODELS_PERSONAL", models_iso.to_str().unwrap()),
        ],
        &[],
    );
    assert_eq!(ic, 0, "install product failed: {iout}\n{ierr}");
    assert_eq!(
        fs::read_to_string(product.join(".b3/home")).unwrap().trim(),
        home_str
    );
    assert!(product.join(".cursor/commands/b3-ship.md").is_file());
    assert!(!product.join(".cursor/skills").exists());

    git_in(
        &product,
        &["add", ".gitignore", ".b3/home", "AGENTS.md", ".cursor"],
    );
    git_in(&product, &["commit", "-qm", "attach b3 pointer"]);
    let run_base = git_in(&product, &["rev-parse", "HEAD"]);

    let (nrc, run_id, _) = run_b3(&[
        "guard",
        "new-run",
        "--repo-root",
        p_str,
        "--slug",
        "add-greet",
    ]);
    assert_eq!(nrc, 0);
    let run_id = run_id.trim();
    let (rrc, run_dir_rel, _) = run_b3(&["guard", "resolve-run", "--repo-root", p_str]);
    assert_eq!(rrc, 0);
    assert_eq!(run_dir_rel, format!(".b3/ship/runs/{run_id}"));

    write_lf(
        &product.join("greet.js"),
        "exports.greet = (n) => 'Hello, ' + n;\n",
    );
    let t1_rec = format!("{run_dir_rel}/evidence/T001.verify");
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            p_str,
            "--verify-cmd",
            "echo t1-greet",
            "--receipt-path",
            &t1_rec,
            "--task-id",
            "T001",
            "--relevant-paths",
            "greet.js"
        ])
        .0,
        0
    );
    git_in(&product, &["add", "greet.js"]);
    assert_eq!(
        run_b3(&[
            "guard",
            "precommit",
            "--repo-root",
            p_str,
            "--allowed-paths",
            "greet.js",
            "--require-verify-receipt",
            &t1_rec
        ])
        .0,
        0
    );
    git_in(&product, &["commit", "-qm", "T001 greet"]);
    let t1_sha = git_in(&product, &["rev-parse", "HEAD"]);

    // Interrupt & resume T002
    write_lf(&product.join("docs/guide.md"), "doc v2\n");
    assert_eq!(
        git_in_status(&product, &["merge-base", "--is-ancestor", &t1_sha, "HEAD"]).0,
        0
    );
    let t2_rec = format!("{run_dir_rel}/evidence/T002.verify");
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            p_str,
            "--verify-cmd",
            "echo t2-doc",
            "--receipt-path",
            &t2_rec,
            "--task-id",
            "T002",
            "--relevant-paths",
            "docs/guide.md"
        ])
        .0,
        0
    );
    git_in(&product, &["add", "docs/guide.md"]);
    assert_eq!(
        run_b3(&[
            "guard",
            "precommit",
            "--repo-root",
            p_str,
            "--allowed-paths",
            "docs/guide.md",
            "--require-verify-receipt",
            &t2_rec
        ])
        .0,
        0
    );
    git_in(&product, &["commit", "-qm", "T002 doc"]);
    assert_eq!(
        git_in_status(
            &product,
            &["merge-base", "--is-ancestor", &run_base, &t1_sha]
        )
        .0,
        0
    );
    let tree_files = git_in(&product, &["ls-tree", "-r", "--name-only", "HEAD"]);
    assert!(!tree_files.contains(".b3/ship/"));
}

#[test]
fn tshirt_boundaries_and_risk_routing() {
    let tmp = TempDirGuard::new("guard-tshirt-risk");
    let repo = tmp.path.join("repo");
    clone_seeded_git_repo(&repo);
    let base = git_in(&repo, &["rev-parse", "HEAD"]);
    let r_str = repo.to_str().unwrap();

    // 1. All 10 LOC boundaries
    for (lines, expected) in [
        (100, "XS"),
        (101, "S"),
        (300, "S"),
        (301, "M"),
        (800, "M"),
        (801, "L"),
        (1999, "L"),
        (2000, "XL"),
        (5000, "XL"),
        (5001, "XXL"),
    ] {
        write_lf(&repo.join("docs/loc.md"), &"doc line\n".repeat(lines));
        git_in(&repo, &["add", "docs/loc.md"]);
        let (c, out, err) = run_b3(&[
            "guard",
            "diff-scope",
            "--repo-root",
            r_str,
            "--base-sha",
            &base,
        ]);
        assert_eq!(c, 0, "lines={lines}: {out}\n{err}");
        assert_eq!(
            extract_kv(&out, "size_class"),
            Some(expected),
            "lines={lines} out={out}"
        );
    }
    git_in(&repo, &["reset", "-q", "HEAD", "--", "docs/loc.md"]);
    fs::remove_file(repo.join("docs/loc.md")).unwrap();

    // 2. All 10 file-count boundaries (grow incrementally 3 -> 4 -> ... -> 101 so each file is created once)
    let files: Vec<String> = (1..=101).map(|i| format!("docs/f{i:03}.md")).collect();
    let mut created = 0usize;
    for (count, expected) in [
        (3, "XS"),
        (4, "S"),
        (8, "S"),
        (9, "M"),
        (20, "M"),
        (21, "L"),
        (49, "L"),
        (50, "XL"),
        (100, "XL"),
        (101, "XXL"),
    ] {
        while created < count {
            write_lf(&repo.join(&files[created]), "d\n");
            created += 1;
        }
        let (c, out, err) = run_b3(&[
            "guard",
            "diff-scope",
            "--repo-root",
            r_str,
            "--base-sha",
            &base,
        ]);
        assert_eq!(c, 0, "files={count}: {out}\n{err}");
        assert_eq!(
            extract_kv(&out, "size_class"),
            Some(expected),
            "files={count} out={out}"
        );
    }
    for f in &files {
        fs::remove_file(repo.join(f)).unwrap();
    }

    // 3. NOISE_ONLY (package-lock.json & Form1.Designer.cs)
    write_lf(&repo.join("Form1.Designer.cs"), "// gen\n");
    let (gc, gout, _) = run_b3(&[
        "guard",
        "diff-scope",
        "--repo-root",
        r_str,
        "--base-sha",
        &base,
    ]);
    assert_eq!(gc, 0);
    assert_eq!(extract_kv(&gout, "size_class"), Some("NOISE_ONLY"));
    assert_eq!(extract_kv(&gout, "risk_signals"), Some("generated_code"));
    fs::remove_file(repo.join("Form1.Designer.cs")).unwrap();

    // 4. Decoupled risk routing: XS+CRITICAL, non-false-positive docs/auth & src/authors, JSON.parse co-signals, ++ // comment
    write_lf(
        &repo.join("src/auth/jwt.ts"),
        &"export function verifyToken(t: string) { return t.length > 0; }\n".repeat(30),
    );
    let (_, out, _) = run_b3(&[
        "guard",
        "diff-scope",
        "--repo-root",
        r_str,
        "--base-sha",
        &base,
    ]);
    assert_eq!(extract_kv(&out, "size_class"), Some("XS"));
    assert_eq!(extract_kv(&out, "risk_level"), Some("CRITICAL"));
    assert_eq!(
        extract_kv(&out, "recommended_specialists"),
        Some("b3-security-reviewer")
    );
    fs::remove_file(repo.join("src/auth/jwt.ts")).unwrap();

    for safe_rel in [
        "docs/auth/guide.md",
        "tests/auth/login.test.ts",
        "src/authors/list.ts",
        "evals/auth/case.yaml",
    ] {
        write_lf(&repo.join(safe_rel), "export const item = 1;\n");
        let (sc, sout, _) = run_b3(&[
            "guard",
            "diff-scope",
            "--repo-root",
            r_str,
            "--base-sha",
            &base,
        ]);
        assert_eq!(sc, 0);
        assert_eq!(
            extract_kv(&sout, "risk_level"),
            Some("LOW"),
            "{safe_rel}: {sout}"
        );
        fs::remove_file(repo.join(safe_rel)).unwrap();
    }

    // JSON.parse co-signals
    write_lf(
        &repo.join("src/util/cfg.ts"),
        "export const loadCfg = (raw: string) => JSON.parse(raw);\n",
    );
    let (_, jp_plain, _) = run_b3(&[
        "guard",
        "review-inventory",
        "--repo-root",
        r_str,
        "--base-sha",
        &base,
    ]);
    assert_eq!(extract_kv(&jp_plain, "risk_level"), Some("LOW"));
    fs::remove_file(repo.join("src/util/cfg.ts")).unwrap();

    write_lf(
        &repo.join("src/api/ingest.ts"),
        "export const ingest = (req: { body: string }) => JSON.parse(req.body);\n",
    );
    let (_, jp_req, _) = run_b3(&[
        "guard",
        "review-inventory",
        "--repo-root",
        r_str,
        "--base-sha",
        &base,
    ]);
    assert_eq!(extract_kv(&jp_req, "risk_level"), Some("HIGH"));
    assert_eq!(
        extract_kv(&jp_req, "risk_signals"),
        Some("public_api_contract")
    );
    fs::remove_file(repo.join("src/api/ingest.ts")).unwrap();

    write_lf(
        &repo.join("src/util/batch.ts"),
        "export const parseBatch = (chunks: string[]) => chunks.map((raw) => JSON.parse(raw));\n",
    );
    let (_, jp_hot, _) = run_b3(&[
        "guard",
        "review-inventory",
        "--repo-root",
        r_str,
        "--base-sha",
        &base,
    ]);
    assert_eq!(extract_kv(&jp_hot, "risk_level"), Some("HIGH"));
    assert_eq!(extract_kv(&jp_hot, "risk_signals"), Some("perf_hot_path"));
    fs::remove_file(repo.join("src/util/batch.ts")).unwrap();

    // ++ // comment tolerance + eval + DROP TABLE -> CRITICAL
    let drop_sql = format!("DROP {} users;", "TABLE");
    write_lf(
        &repo.join("src/util.js"),
        &format!("export const ok = 1;\n++ // note\neval(userInput); {drop_sql}\n"),
    );
    let (_, cmt_out, _) = run_b3(&[
        "guard",
        "diff-scope",
        "--repo-root",
        r_str,
        "--base-sha",
        &base,
    ]);
    assert_eq!(extract_kv(&cmt_out, "risk_level"), Some("CRITICAL"));
    fs::remove_file(repo.join("src/util.js")).unwrap();

    // diff.noprefix + diff.mnemonicPrefix with path `a/x.ts`
    let np_repo = tmp.path.join("noprefix-repo");
    clone_seeded_git_repo(&np_repo);
    git_in(&np_repo, &["config", "diff.noprefix", "true"]);
    git_in(&np_repo, &["config", "diff.mnemonicPrefix", "true"]);
    write_lf(&np_repo.join("a/x.ts"), "export const x = 0;\n");
    git_in(&np_repo, &["add", "."]);
    git_in(&np_repo, &["commit", "-qm", "base"]);
    let np_base = git_in(&np_repo, &["rev-parse", "HEAD"]);
    write_lf(
        &np_repo.join("a/x.ts"),
        "export function verifyToken(t: string) { return jwt.verify(t, 'k'); }\n",
    );
    let (_, np_out, _) = run_b3(&[
        "guard",
        "review-inventory",
        "--repo-root",
        np_repo.to_str().unwrap(),
        "--base-sha",
        &np_base,
    ]);
    assert!(
        np_out.contains("unit|U01|a|1|2|CRITICAL|b3-security-reviewer|auth_security|a/x.ts"),
        "{np_out}"
    );
}

#[test]
fn hierarchical_inventory_25k_30k_and_partition_gates() {
    let tmp = TempDirGuard::new("guard-hier-inv");

    // 1. 25k+ LOC mixed PR with test pairing
    let r25 = tmp.path.join("repo-25k");
    clone_seeded_git_repo(&r25);
    let base25 = git_in(&r25, &["rev-parse", "HEAD"]);
    git_in(&r25, &["checkout", "-qb", "feat/huge-pr"]);
    write_lf(
        &r25.join("src/auth/jwt.ts"),
        &"export function verifyToken(tok: string) { return tok !== ''; }\n".repeat(120),
    );
    write_lf(
        &r25.join("tests/auth/jwt.test.ts"),
        &"export const authTest = true;\n".repeat(40),
    );
    write_lf(
        &r25.join("src/contracts/order.ts"),
        &"export interface OrderDto { id: string; }\n".repeat(150),
    );
    write_lf(
        &r25.join("src/render/scene.ts"),
        &"export function onTick() { useFrame(() => {}); }\n".repeat(150),
    );
    for d in [
        "docs/api/spec.md",
        "docs/arch/design.md",
        "docs/ops/runbook.md",
    ] {
        write_lf(&r25.join(d), &"Detailed guide content line.\n".repeat(4000));
    }
    for m in 1..=16 {
        for f in 1..=7 {
            write_lf(
                &r25.join(format!("src/m{m:02}/file{f}.ts")),
                &format!("export const v_{m}_{f} = {f};\n").repeat(120),
            );
        }
    }
    git_in(&r25, &["add", "."]);
    git_in(&r25, &["commit", "-qm", "25k mixed PR"]);
    let pr25_sha = git_in(&r25, &["rev-parse", "HEAD"]);
    git_in(&r25, &["checkout", "-q", "-b", "main-check", &base25]);

    let (c25, out25, err25) = run_b3(&[
        "guard",
        "review-inventory",
        "--repo-root",
        r25.to_str().unwrap(),
        "--base-sha",
        &base25,
        "--target-ref",
        &pr25_sha,
        "--max-concurrency",
        "4",
    ]);
    assert_eq!(c25, 0, "{out25}\n{err25}");
    assert_eq!(extract_kv(&out25, "size_class"), Some("XXL"));
    assert_eq!(extract_kv(&out25, "risk_level"), Some("CRITICAL"));
    assert_eq!(
        extract_kv(&out25, "l1_specialists"),
        Some("b3-architecture-reviewer,b3-performance-reviewer,b3-security-reviewer")
    );
    assert_eq!(extract_kv(&out25, "l1_skip_rationale"), Some("none"));
    assert!(
        out25.contains("src/auth/jwt.ts,tests/auth/jwt.test.ts"),
        "{out25}"
    );
    let uc25: usize = extract_kv(&out25, "unit_count").unwrap().parse().unwrap();
    assert!(uc25 >= 22, "uc25={uc25}");

    // 2. 30k+ LOC flat directory subdivision + PARTITION_INCOMPLETE + >100f deeper split
    let r30 = tmp.path.join("repo-30k");
    clone_seeded_git_repo(&r30);
    let base30 = git_in(&r30, &["rev-parse", "HEAD"]);
    write_lf(
        &r30.join("src/monolith/api.proto"),
        &"message Order { string id = 1; }\n".repeat(120),
    );
    write_lf(
        &r30.join("src/monolith/alpha_gate.ts"),
        &format!(
            "import {{ runAuth }} from './auth_core';\nexport const gate = () => runAuth();\n{}",
            "export const g = 1;\n".repeat(80)
        ),
    );
    write_lf(
        &r30.join("src/monolith/auth_core.ts"),
        &"export function runAuth() { return true; }\n".repeat(3000),
    );
    write_lf(
        &r30.join("src/monolith/alpha_gate.test.ts"),
        &"export const gateTest = true;\n".repeat(60),
    );
    for idx in 1..=6 {
        let fn_name = format!("feat{idx:02}");
        write_lf(
            &r30.join(format!("src/monolith/{fn_name}_model.ts")),
            &format!("export interface {fn_name}Dto {{ id: number; }}\n").repeat(2200),
        );
        write_lf(
            &r30.join(format!("src/monolith/{fn_name}_service.ts")),
            &format!(
                "import type {{ {fn_name}Dto }} from './{fn_name}_model';\nexport const make_{fn_name} = (x: {fn_name}Dto) => x;\n{}",
                format!("export const line_{fn_name} = 1;\n").repeat(2200)
            ),
        );
        write_lf(
            &r30.join(format!("src/monolith/{fn_name}.test.ts")),
            &format!("export const test_{fn_name} = true;\n").repeat(40),
        );
    }
    write_lf(
        &r30.join("src/monolith/sync_tool.ps1"),
        &"# ps helper\n".repeat(2600),
    );
    write_lf(
        &r30.join("src/monolith/sync_tool.sh"),
        &"# sh helper\n".repeat(2600),
    );
    git_in(&r30, &["add", "."]);
    git_in(&r30, &["commit", "-qm", "30k flat dir"]);
    let r30_str = r30.to_str().unwrap();

    let (c30, out30, err30) = run_b3(&[
        "guard",
        "review-inventory",
        "--repo-root",
        r30_str,
        "--base-sha",
        &base30,
        "--max-concurrency",
        "4",
    ]);
    assert_eq!(c30, 0, "{out30}\n{err30}");
    let unit_lines: Vec<&str> = out30.lines().filter(|l| l.starts_with("unit|")).collect();
    assert!(unit_lines.len() >= 9, "{out30}");
    for ul in &unit_lines {
        let cols: Vec<&str> = ul.split('|').collect();
        let ufc: usize = cols[3].parse().unwrap();
        let ulc: usize = cols[4].parse().unwrap();
        assert!(
            ulc <= 5000 && !(ufc > 100 && ulc > 1000),
            "unbounded unit: {ul}"
        );
    }

    // Indivisible >5000L single file -> PARTITION_INCOMPLETE exit 2
    write_lf(
        &r30.join("src/monolith/giant.ts"),
        &"export const big = 1;\n".repeat(5100),
    );
    let (gc, gout, gerr) = run_b3(&[
        "guard",
        "review-inventory",
        "--repo-root",
        r30_str,
        "--base-sha",
        &base30,
    ]);
    assert_eq!(gc, 2);
    assert!(
        gerr.contains("PARTITION_INCOMPLETE:") || gout.contains("PARTITION_INCOMPLETE:"),
        "{gout}\n{gerr}"
    );
    fs::remove_file(r30.join("src/monolith/giant.ts")).unwrap();

    // Coupled 2-file import >5000L -> PARTITION_INCOMPLETE exit 2
    write_lf(
        &r30.join("src/monolith/mono_a.ts"),
        &format!(
            "import {{ mb }} from './mono_b';\nexport const ma = () => mb;\n{}",
            "export const aLine = 1;\n".repeat(3000)
        ),
    );
    write_lf(
        &r30.join("src/monolith/mono_b.ts"),
        &"export const mb = 2;\n".repeat(3000),
    );
    let (cc, cout, cerr) = run_b3(&[
        "guard",
        "review-inventory",
        "--repo-root",
        r30_str,
        "--base-sha",
        &base30,
    ]);
    assert_eq!(cc, 2);
    assert!(
        cerr.contains("PARTITION_INCOMPLETE:") || cout.contains("PARTITION_INCOMPLETE:"),
        "{cout}\n{cerr}"
    );

    // >100f deeper directory split (110 files across sub1 & sub2)
    let r110 = tmp.path.join("repo-110f");
    clone_seeded_git_repo(&r110);
    let base110 = git_in(&r110, &["rev-parse", "HEAD"]);
    for sd in ["sub1", "sub2"] {
        for i in 1..=55 {
            write_lf(
                &r110.join(format!("src/bigmod/{sd}/f{i}.ts")),
                &format!("export const v = {i};\n").repeat(15),
            );
        }
    }
    let (c110, out110, _) = run_b3(&[
        "guard",
        "review-inventory",
        "--repo-root",
        r110.to_str().unwrap(),
        "--base-sha",
        &base110,
    ]);
    assert_eq!(c110, 0);
    assert!(
        out110.contains("unit|U01|src/bigmod/sub1|55|825|"),
        "{out110}"
    );
    assert!(
        out110.contains("unit|U02|src/bigmod/sub2|55|825|"),
        "{out110}"
    );

    // 3. L/XL max-4-unit cap + hand-crafted 5-unit check fail + post-init >5000L growth fail
    let r_cap = tmp.path.join("repo-cap");
    clone_seeded_git_repo(&r_cap);
    let base_cap = git_in(&r_cap, &["rev-parse", "HEAD"]);
    for d in [
        "src/alpha",
        "src/beta",
        "src/gamma",
        "src/delta",
        "apps/web",
        "apps/admin",
        "ops/scripts",
    ] {
        write_lf(
            &r_cap.join(format!("{d}/mod.ts")),
            &"export const val = 1;\n".repeat(180),
        );
    }
    write_lf(
        &r_cap.join("tests/alpha/alpha.test.ts"),
        &"export const tAlpha = true;\n".repeat(30),
    );
    git_in(&r_cap, &["add", "."]);
    git_in(&r_cap, &["commit", "-qm", "7-dir L PR"]);
    let rc_str = r_cap.to_str().unwrap();
    let (cl, out_l, _) = run_b3(&[
        "guard",
        "review-inventory",
        "--repo-root",
        rc_str,
        "--base-sha",
        &base_cap,
    ]);
    assert_eq!(cl, 0);
    assert_eq!(extract_kv(&out_l, "size_class"), Some("L"));
    let uc_l: usize = extract_kv(&out_l, "unit_count").unwrap().parse().unwrap();
    assert!((2..=4).contains(&uc_l), "uc_l={uc_l}");

    assert_eq!(
        run_b3(&[
            "guard",
            "review-ledger",
            "--repo-root",
            rc_str,
            "--action",
            "init",
            "--ledger-path",
            ".b3/ship/cap.md",
            "--base-sha",
            &base_cap
        ])
        .0,
        0
    );
    let cap_txt = fs::read_to_string(r_cap.join(".b3/ship/cap.md")).unwrap();
    let over5 = cap_txt.replace("unit_count=4", "unit_count=5")
        + "| U05 | extra/m | 1 | 10 | LOW | none | none | PENDING | none | none | none | README.md |\n";
    write_lf(&r_cap.join(".b3/ship/over5.md"), &over5);
    let (o5_c, _, o5_err) = run_b3(&[
        "guard",
        "review-ledger",
        "--repo-root",
        rc_str,
        "--action",
        "check",
        "--ledger-path",
        ".b3/ship/over5.md",
    ]);
    assert_eq!(o5_c, 2);
    assert!(
        o5_err.contains("LEDGER_INCOMPLETE: L PR exceeds max 4 units (5)"),
        "{o5_err}"
    );

    // XXL low-risk docs skip rationale
    let r_docs = tmp.path.join("repo-xxl-docs");
    clone_seeded_git_repo(&r_docs);
    let base_docs = git_in(&r_docs, &["rev-parse", "HEAD"]);
    for sec in ["part1", "part2", "part3", "part4"] {
        for i in 1..=26 {
            write_lf(
                &r_docs.join(format!("docs/{sec}/doc{i:02}.md")),
                &"Guide content line.\n".repeat(210),
            );
        }
    }
    let (dx_c, dx_out, _) = run_b3(&[
        "guard",
        "review-inventory",
        "--repo-root",
        r_docs.to_str().unwrap(),
        "--base-sha",
        &base_docs,
    ]);
    assert_eq!(dx_c, 0);
    assert_eq!(extract_kv(&dx_out, "size_class"), Some("XXL"));
    assert_eq!(extract_kv(&dx_out, "risk_level"), Some("LOW"));
    assert_eq!(
        extract_kv(&dx_out, "l1_skip_rationale"),
        Some("low-risk-docs-only")
    );
}

#[test]
fn review_ledger_security_tamper_and_independence() {
    let tmp = TempDirGuard::new("guard-ledger-sec");

    // 1. Full ledger lifecycle, CRITICAL specialist+receipt, contract invalidation, branch move, C-03 head_sha binding
    let repo = tmp.path.join("ledger-repo");
    clone_seeded_git_repo(&repo);
    let base = git_in(&repo, &["rev-parse", "HEAD"]);
    git_in(&repo, &["checkout", "-qb", "pr-branch"]);
    write_lf(&repo.join("docs/notes.md"), &"Docs line.\n".repeat(805));
    write_lf(
        &repo.join("src/auth/login.ts"),
        "export function verifyToken(t: string) { return t.length > 0; }\n",
    );
    write_lf(
        &repo.join("src/contracts/order.ts"),
        "export interface Order { id: string; }\n",
    );
    write_lf(
        &repo.join("src/orders/handler.ts"),
        "import type { Order } from '../contracts/order';\nexport const makeOrder = (o: Order) => o;\n",
    );
    git_in(&repo, &["add", "."]);
    git_in(&repo, &["commit", "-qm", "work"]);
    let r_str = repo.to_str().unwrap();

    let lp = ".b3/ship/ledger.md";
    let (ic, iout, _) = run_b3(&[
        "guard",
        "review-ledger",
        "--repo-root",
        r_str,
        "--action",
        "init",
        "--ledger-path",
        lp,
        "--base-sha",
        &base,
        "--target-ref",
        "pr-branch",
        "--max-passes",
        "15",
        "--review-independence",
        "INDEPENDENT",
    ]);
    assert_eq!(ic, 0);
    assert!(iout.contains("size=L risk=CRITICAL units=4"), "{iout}");

    let led_txt = fs::read_to_string(repo.join(lp)).unwrap();
    let umap = parse_unit_ids_by_files(&led_txt);
    let u_doc = &umap["docs/notes.md"];
    let u_auth = &umap["src/auth/login.ts"];
    let u_con = &umap["src/contracts/order.ts"];
    let u_ord = &umap["src/orders/handler.ts"];

    // R002: self-declared CRITICAL WAIVER: (and lowercase waiver:) rejected as LEDGER_BLOCKED
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            r_str,
            "--verify-cmd",
            "echo auth-ok",
            "--receipt-path",
            ".b3/ship/u_auth.verify",
            "--relevant-paths",
            "src/auth/login.ts"
        ])
        .0,
        0
    );
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            r_str,
            "--verify-cmd",
            "echo con-ok",
            "--receipt-path",
            ".b3/ship/u_con.verify",
            "--relevant-paths",
            "src/contracts/order.ts"
        ])
        .0,
        0
    );

    assert_eq!(
        run_b3(&[
            "guard",
            "review-ledger",
            "--repo-root",
            r_str,
            "--action",
            "update",
            "--ledger-path",
            lp,
            "--unit-id",
            u_doc,
            "--status",
            "REVIEWED"
        ])
        .0,
        0
    );
    // HIGH skip rationale: update stores provided rationale; check enforces non-empty non-none non-waiver rationale
    assert_eq!(
        run_b3(&[
            "guard",
            "review-ledger",
            "--repo-root",
            r_str,
            "--action",
            "update",
            "--ledger-path",
            lp,
            "--unit-id",
            u_con,
            "--status",
            "REVIEWED",
            "--receipt-path",
            ".b3/ship/u_con.verify",
            "--rationale",
            "aaaaa"
        ])
        .0,
        0
    );
    assert_eq!(
        run_b3(&[
            "guard",
            "review-ledger",
            "--repo-root",
            r_str,
            "--action",
            "update",
            "--ledger-path",
            lp,
            "--unit-id",
            u_ord,
            "--status",
            "REVIEWED"
        ])
        .0,
        0
    );
    for waiver in [
        "WAIVER:approved_by=sec-lead@corp;ticket=SEC-404;reason=Pure DTO mapper verified",
        "waiver:approved_by=sec-lead@corp;ticket=SEC-404;reason=lowercase check",
    ] {
        assert_eq!(
            run_b3(&[
                "guard",
                "review-ledger",
                "--repo-root",
                r_str,
                "--action",
                "update",
                "--ledger-path",
                lp,
                "--unit-id",
                u_auth,
                "--status",
                "REVIEWED",
                "--receipt-path",
                ".b3/ship/u_auth.verify",
                "--rationale",
                waiver
            ])
            .0,
            0
        );
        let (wc, _, werr) = run_b3(&[
            "guard",
            "review-ledger",
            "--repo-root",
            r_str,
            "--action",
            "check",
            "--ledger-path",
            lp,
        ]);
        assert_eq!(wc, 2);
        assert!(
            werr.contains("LEDGER_BLOCKED: unverified CRITICAL specialist waiver rejected"),
            "{werr}"
        );
    }

    // Complete u_auth with mandatory specialist; "none" rationale on u_con still blocks
    assert_eq!(
        run_b3(&[
            "guard",
            "review-ledger",
            "--repo-root",
            r_str,
            "--action",
            "update",
            "--ledger-path",
            lp,
            "--unit-id",
            u_auth,
            "--status",
            "REVIEWED",
            "--specialists",
            "b3-security-reviewer",
            "--rationale",
            "none",
            "--receipt-path",
            ".b3/ship/u_auth.verify"
        ])
        .0,
        0
    );
    assert_eq!(
        run_b3(&[
            "guard",
            "review-ledger",
            "--repo-root",
            r_str,
            "--action",
            "update",
            "--ledger-path",
            lp,
            "--unit-id",
            u_con,
            "--status",
            "REVIEWED",
            "--receipt-path",
            ".b3/ship/u_con.verify",
            "--rationale",
            "none"
        ])
        .0,
        0
    );
    let (wkc, _, wk_err) = run_b3(&[
        "guard",
        "review-ledger",
        "--repo-root",
        r_str,
        "--action",
        "check",
        "--ledger-path",
        lp,
    ]);
    assert_eq!(wkc, 2);
    assert!(wk_err.contains("valid HIGH skip rationale"), "{wk_err}");

    // Concise explicit rationale (<15 chars, no prose-shape proxy) is accepted on HIGH
    assert_eq!(
        run_b3(&[
            "guard",
            "review-ledger",
            "--repo-root",
            r_str,
            "--action",
            "update",
            "--ledger-path",
            lp,
            "--unit-id",
            u_con,
            "--status",
            "REVIEWED",
            "--receipt-path",
            ".b3/ship/u_con.verify",
            "--rationale",
            "docs-only"
        ])
        .0,
        0
    );
    assert_eq!(
        run_b3(&[
            "guard",
            "review-ledger",
            "--repo-root",
            r_str,
            "--action",
            "update",
            "--ledger-path",
            lp,
            "--cross-unit-status",
            "REVIEWED"
        ])
        .0,
        0
    );
    let (pc, pout, _) = run_b3(&[
        "guard",
        "review-ledger",
        "--repo-root",
        r_str,
        "--action",
        "check",
        "--ledger-path",
        lp,
    ]);
    assert_eq!(pc, 0, "{pout}");
    assert!(pout.contains("LEDGER_GATE_PASS:"), "{pout}");

    // CF-08 overwrite guard: refuses re-init without --force, allows with --force
    let (ov_c, _, ov_err) = run_b3(&[
        "guard",
        "review-ledger",
        "--repo-root",
        r_str,
        "--action",
        "init",
        "--ledger-path",
        lp,
        "--base-sha",
        &base,
        "--target-ref",
        "pr-branch",
        "--review-independence",
        "INDEPENDENT",
    ]);
    assert_eq!(ov_c, 1);
    assert!(ov_err.contains("cannot reset active ledger"), "{ov_err}");

    // Dependent contract edit invalidates ledger (working-tree ledger mode tracks live contract bytes)
    let wt_lp = ".b3/ship/ledger-wt.md";
    assert_eq!(
        run_b3(&[
            "guard",
            "review-ledger",
            "--repo-root",
            r_str,
            "--action",
            "init",
            "--ledger-path",
            wt_lp,
            "--base-sha",
            &base,
            "--max-passes",
            "15",
            "--review-independence",
            "INDEPENDENT"
        ])
        .0,
        0
    );
    for (uid, sp, rec, rat) in [
        (u_doc, "none", "none", "none"),
        (
            u_auth,
            "b3-security-reviewer",
            ".b3/ship/u_auth.verify",
            "none",
        ),
        (
            u_con,
            "none",
            ".b3/ship/u_con.verify",
            "CONFIRMED inline that additive field preserves wire compat",
        ),
        (u_ord, "none", "none", "none"),
    ] {
        assert_eq!(
            run_b3(&[
                "guard",
                "review-ledger",
                "--repo-root",
                r_str,
                "--action",
                "update",
                "--ledger-path",
                wt_lp,
                "--unit-id",
                uid,
                "--status",
                "REVIEWED",
                "--specialists",
                sp,
                "--receipt-path",
                rec,
                "--rationale",
                rat,
            ])
            .0,
            0
        );
    }
    assert_eq!(
        run_b3(&[
            "guard",
            "review-ledger",
            "--repo-root",
            r_str,
            "--action",
            "update",
            "--ledger-path",
            wt_lp,
            "--cross-unit-status",
            "REVIEWED"
        ])
        .0,
        0
    );
    write_lf(
        &repo.join("src/contracts/order.ts"),
        "export interface Order { id: string; total: number; }\n",
    );
    let (dc, _, derr) = run_b3(&[
        "guard",
        "review-ledger",
        "--repo-root",
        r_str,
        "--action",
        "check",
        "--ledger-path",
        wt_lp,
    ]);
    assert_eq!(dc, 2);
    assert!(
        derr.contains("LEDGER_STALE:")
            && derr.contains("invalidated (files or shared contracts changed)"),
        "{derr}"
    );

    // C-03 head_sha binding: receipt generated on `main` even with identical file bytes rejected on `pr-branch`
    let c03_repo = tmp.path.join("c03-repo");
    clone_seeded_git_repo(&c03_repo);
    write_lf(
        &c03_repo.join("src/contracts/api.ts"),
        "export interface Api { v: 1; }\n",
    );
    git_in(&c03_repo, &["add", "."]);
    git_in(&c03_repo, &["commit", "-qm", "base"]);
    let c03_base = git_in(&c03_repo, &["rev-parse", "HEAD"]);
    git_in(&c03_repo, &["checkout", "-qb", "pr-branch"]);
    write_lf(
        &c03_repo.join("src/contracts/api.ts"),
        "export interface Api { v: 2; id: string; }\n",
    );
    git_in(&c03_repo, &["add", "."]);
    git_in(&c03_repo, &["commit", "-qm", "pr"]);
    let c03_str = c03_repo.to_str().unwrap();
    git_in(&c03_repo, &["checkout", "-q", "main"]);
    write_lf(
        &c03_repo.join("src/contracts/api.ts"),
        "export interface Api { v: 2; id: string; }\n",
    );
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            c03_str,
            "--verify-cmd",
            "echo main",
            "--receipt-path",
            ".b3/ship/main.verify",
            "--relevant-paths",
            "src/contracts/api.ts"
        ])
        .0,
        0
    );
    git_in(&c03_repo, &["checkout", "--", "src/contracts/api.ts"]);
    assert_eq!(
        run_b3(&[
            "guard",
            "review-ledger",
            "--repo-root",
            c03_str,
            "--action",
            "init",
            "--ledger-path",
            ".b3/ship/c03.md",
            "--base-sha",
            &c03_base,
            "--target-ref",
            "pr-branch",
            "--review-independence",
            "INDEPENDENT"
        ])
        .0,
        0
    );
    assert_eq!(
        run_b3(&[
            "guard",
            "review-ledger",
            "--repo-root",
            c03_str,
            "--action",
            "update",
            "--ledger-path",
            ".b3/ship/c03.md",
            "--unit-id",
            "U01",
            "--status",
            "REVIEWED",
            "--specialists",
            "b3-architecture-reviewer",
            "--receipt-path",
            ".b3/ship/main.verify"
        ])
        .0,
        0
    );
    let (c03_c, _, c03_err) = run_b3(&[
        "guard",
        "review-ledger",
        "--repo-root",
        c03_str,
        "--action",
        "check",
        "--ledger-path",
        ".b3/ship/c03.md",
    ]);
    assert_eq!(c03_c, 2);
    assert!(c03_err.contains("VERIFY_STALE: head_sha="), "{c03_err}");

    // 2. Branch move + escalation M->L + LOW->CRITICAL + pass_chain tamper + H-06 max_passes
    let esc_repo = tmp.path.join("esc-repo");
    clone_seeded_git_repo(&esc_repo);
    let esc_base = git_in(&esc_repo, &["rev-parse", "HEAD"]);
    write_lf(&esc_repo.join("docs/notes.md"), &"Doc line\n".repeat(500));
    git_in(&esc_repo, &["add", "."]);
    git_in(&esc_repo, &["commit", "-qm", "m-500"]);
    let esc_str = esc_repo.to_str().unwrap();
    assert_eq!(
        run_b3(&[
            "guard",
            "review-ledger",
            "--repo-root",
            esc_str,
            "--action",
            "init",
            "--ledger-path",
            ".b3/ship/esc.md",
            "--base-sha",
            &esc_base,
            "--max-passes",
            "3",
            "--review-independence",
            "INDEPENDENT"
        ])
        .0,
        0
    );
    assert_eq!(
        run_b3(&[
            "guard",
            "review-ledger",
            "--repo-root",
            esc_str,
            "--action",
            "update",
            "--ledger-path",
            ".b3/ship/esc.md",
            "--unit-id",
            "U01",
            "--status",
            "REVIEWED"
        ])
        .0,
        0
    );

    // H-06: raising max_passes rejected (3->8)
    let (mp_c, _, mp_err) = run_b3(&[
        "guard",
        "review-ledger",
        "--repo-root",
        esc_str,
        "--action",
        "update",
        "--ledger-path",
        ".b3/ship/esc.md",
        "--max-passes",
        "8",
    ]);
    assert_eq!(mp_c, 1);
    assert!(
        mp_err.contains("LEDGER_CORRUPT: cannot raise max_passes (3->8)"),
        "{mp_err}"
    );

    // Legacy pass_chain / Pass Log lines remain backward-compatible on read; corrupt passes_used fails LEDGER_CORRUPT
    let esc_raw = fs::read_to_string(esc_repo.join(".b3/ship/esc.md")).unwrap();
    let mut with_legacy = String::new();
    for line in esc_raw.lines() {
        with_legacy.push_str(line);
        with_legacy.push('\n');
        if line.starts_with("passes_used=") {
            with_legacy.push_str("pass_chain=0123456789abcdef0123456789abcdef01234567\n");
        }
    }
    with_legacy.push_str("\n## Pass Log\npass|1|U01|unit:REVIEWED|1|abc|def\n");
    write_lf(&esc_repo.join(".b3/ship/esc-legacy.md"), &with_legacy);
    let (leg_c, _, leg_err) = run_b3(&[
        "guard",
        "review-ledger",
        "--repo-root",
        esc_str,
        "--action",
        "check",
        "--ledger-path",
        ".b3/ship/esc-legacy.md",
    ]);
    assert!(
        leg_c != 1,
        "legacy pass_chain lines must not trigger LEDGER_CORRUPT: {leg_err}"
    );
    let corrupt_passes = esc_raw.replace("passes_used=1", "passes_used=notanint");
    write_lf(&esc_repo.join(".b3/ship/esc-corrupt.md"), &corrupt_passes);
    let (st_c, _, st_err) = run_b3(&[
        "guard",
        "review-ledger",
        "--repo-root",
        esc_str,
        "--action",
        "check",
        "--ledger-path",
        ".b3/ship/esc-corrupt.md",
    ]);
    assert_eq!(st_c, 1);
    assert!(st_err.contains("LEDGER_CORRUPT:"), "{st_err}");

    // M -> L escalation
    write_lf(&esc_repo.join("docs/notes.md"), &"Doc line\n".repeat(850));
    git_in(&esc_repo, &["add", "."]);
    git_in(&esc_repo, &["commit", "-qm", "l-850"]);
    assert_eq!(
        run_b3(&[
            "guard",
            "review-ledger",
            "--repo-root",
            esc_str,
            "--action",
            "update",
            "--ledger-path",
            ".b3/ship/esc.md",
            "--unit-id",
            "U01",
            "--status",
            "REVIEWED"
        ])
        .0,
        0
    );
    let (ml_c, _, ml_err) = run_b3(&[
        "guard",
        "review-ledger",
        "--repo-root",
        esc_str,
        "--action",
        "check",
        "--ledger-path",
        ".b3/ship/esc.md",
    ]);
    assert_eq!(ml_c, 2);
    assert!(
        ml_err.contains("LEDGER_STALE: size_class escalated (M->L)"),
        "{ml_err}"
    );

    // 3. H-08 review_independence: UNKNOWN default, SINGLE_AGENT_LIMIT blocks HIGH/CRITICAL, irreversible, normalize backfill
    let h08_repo = tmp.path.join("h08-repo");
    clone_seeded_git_repo(&h08_repo);
    let h08_base = git_in(&h08_repo, &["rev-parse", "HEAD"]);
    write_lf(
        &h08_repo.join("src/contracts/api.ts"),
        "export interface ContractA { id: string; }\n",
    );
    git_in(&h08_repo, &["add", "."]);
    git_in(&h08_repo, &["commit", "-qm", "high-diff"]);
    let h08_str = h08_repo.to_str().unwrap();
    assert_eq!(
        run_b3(&[
            "guard",
            "verify-run",
            "--repo-root",
            h08_str,
            "--verify-cmd",
            "echo h08",
            "--receipt-path",
            ".b3/ship/h08.verify",
            "--relevant-paths",
            "src/contracts/api.ts"
        ])
        .0,
        0
    );

    // Default init writes UNKNOWN -> blocks HIGH
    assert_eq!(
        run_b3(&[
            "guard",
            "review-ledger",
            "--repo-root",
            h08_str,
            "--action",
            "init",
            "--ledger-path",
            ".b3/ship/h08-unk.md",
            "--base-sha",
            &h08_base
        ])
        .0,
        0
    );
    assert!(fs::read_to_string(h08_repo.join(".b3/ship/h08-unk.md"))
        .unwrap()
        .contains("review_independence=UNKNOWN\n"));
    assert_eq!(
        run_b3(&[
            "guard",
            "review-ledger",
            "--repo-root",
            h08_str,
            "--action",
            "update",
            "--ledger-path",
            ".b3/ship/h08-unk.md",
            "--unit-id",
            "U01",
            "--status",
            "REVIEWED",
            "--specialists",
            "b3-architecture-reviewer",
            "--receipt-path",
            ".b3/ship/h08.verify"
        ])
        .0,
        0
    );
    let (uh_c, _, uh_err) = run_b3(&[
        "guard",
        "review-ledger",
        "--repo-root",
        h08_str,
        "--action",
        "check",
        "--ledger-path",
        ".b3/ship/h08-unk.md",
    ]);
    assert_eq!(uh_c, 2);
    assert!(
        uh_err.contains("review_independence_unknown_blocks_high_risk"),
        "{uh_err}"
    );

    // SINGLE_AGENT_LIMIT blocks HIGH and cannot upgrade to INDEPENDENT or clear to UNKNOWN
    assert_eq!(
        run_b3(&[
            "guard",
            "review-ledger",
            "--repo-root",
            h08_str,
            "--action",
            "init",
            "--ledger-path",
            ".b3/ship/h08-sal.md",
            "--base-sha",
            &h08_base,
            "--review-independence",
            "SINGLE_AGENT_LIMIT"
        ])
        .0,
        0
    );
    assert_eq!(
        run_b3(&[
            "guard",
            "review-ledger",
            "--repo-root",
            h08_str,
            "--action",
            "update",
            "--ledger-path",
            ".b3/ship/h08-sal.md",
            "--unit-id",
            "U01",
            "--status",
            "REVIEWED",
            "--specialists",
            "b3-architecture-reviewer",
            "--receipt-path",
            ".b3/ship/h08.verify"
        ])
        .0,
        0
    );
    let (sh_c, _, sh_err) = run_b3(&[
        "guard",
        "review-ledger",
        "--repo-root",
        h08_str,
        "--action",
        "check",
        "--ledger-path",
        ".b3/ship/h08-sal.md",
    ]);
    assert_eq!(sh_c, 2);
    assert!(
        sh_err.contains("single_agent_limit_blocks_high_risk"),
        "{sh_err}"
    );
    let (upg_c, _, upg_err) = run_b3(&[
        "guard",
        "review-ledger",
        "--repo-root",
        h08_str,
        "--action",
        "update",
        "--ledger-path",
        ".b3/ship/h08-sal.md",
        "--review-independence",
        "INDEPENDENT",
    ]);
    assert_eq!(upg_c, 1);
    assert!(
        upg_err.contains("cannot upgrade SINGLE_AGENT_LIMIT to INDEPENDENT"),
        "{upg_err}"
    );
    let (clr_c, _, clr_err) = run_b3(&[
        "guard",
        "review-ledger",
        "--repo-root",
        h08_str,
        "--action",
        "update",
        "--ledger-path",
        ".b3/ship/h08-sal.md",
        "--review-independence",
        "UNKNOWN",
    ]);
    assert_eq!(clr_c, 1);
    assert!(
        clr_err.contains("cannot clear SINGLE_AGENT_LIMIT"),
        "{clr_err}"
    );

    // Stripped review_independence fails LEDGER_CORRUPT; normalize backfills UNKNOWN
    let sal_raw = fs::read_to_string(h08_repo.join(".b3/ship/h08-sal.md")).unwrap();
    let no_ri: String = sal_raw
        .lines()
        .filter(|l| !l.starts_with("review_independence="))
        .collect::<Vec<_>>()
        .join("\n")
        + "\n";
    write_lf(&h08_repo.join(".b3/ship/h08-nori.md"), &no_ri);
    assert_eq!(
        run_b3(&[
            "guard",
            "review-ledger",
            "--repo-root",
            h08_str,
            "--action",
            "check",
            "--ledger-path",
            ".b3/ship/h08-nori.md"
        ])
        .0,
        1
    );
    assert_eq!(
        run_b3(&[
            "guard",
            "review-ledger",
            "--repo-root",
            h08_str,
            "--action",
            "normalize",
            "--ledger-path",
            ".b3/ship/h08-nori.md"
        ])
        .0,
        0
    );
    assert!(fs::read_to_string(h08_repo.join(".b3/ship/h08-nori.md"))
        .unwrap()
        .contains("review_independence=UNKNOWN\n"));

    // XXL scaled max_passes (8 units -> 24, 11 units -> 30)
    let r_xxl = tmp.path.join("xxl-pass-scale");
    clone_seeded_git_repo(&r_xxl);
    let xxl_base = git_in(&r_xxl, &["rev-parse", "HEAD"]);
    for i in 1..=8 {
        write_lf(
            &r_xxl.join(format!("docs/s{i:02}/part.md")),
            &"Doc line\n".repeat(700),
        );
    }
    let (u8_c, u8_out, _) = run_b3(&[
        "guard",
        "review-ledger",
        "--repo-root",
        r_xxl.to_str().unwrap(),
        "--action",
        "init",
        "--ledger-path",
        ".b3/ship/u8.md",
        "--base-sha",
        &xxl_base,
    ]);
    assert_eq!(u8_c, 0);
    assert!(u8_out.contains("units=8 max_passes=24 "), "{u8_out}");
    for i in 9..=11 {
        write_lf(
            &r_xxl.join(format!("docs/s{i:02}/part.md")),
            &"Doc line\n".repeat(700),
        );
    }
    let (u11_c, u11_out, _) = run_b3(&[
        "guard",
        "review-ledger",
        "--repo-root",
        r_xxl.to_str().unwrap(),
        "--action",
        "init",
        "--ledger-path",
        ".b3/ship/u11.md",
        "--base-sha",
        &xxl_base,
    ]);
    assert_eq!(u11_c, 0);
    assert!(u11_out.contains("units=11 max_passes=30 "), "{u11_out}");

    // Silence unused helper warning on Unix/Windows if create_file_link isn't invoked on Windows
    let _ = create_file_link as fn(&Path, &Path);
}

#[test]
fn symbol_check_literal_pathspec_handles_bracketed_route_paths() {
    let tmp = TempDirGuard::new("sym-literal");
    let repo = tmp.path.join("repo");
    clone_seeded_git_repo(&repo);
    let r = repo.to_str().unwrap();

    // Multi-symbol diff with `[id]` route directory so scoped `git grep` uses `:(literal)`
    write_lf(
        &repo.join("src/[id]/page.tsx"),
        "export function removedAlpha() { return 1; }\nexport function removedBeta() { return 2; }\nexport const useBoth = () => removedAlpha() + removedBeta();\n",
    );
    git_in(&repo, &["add", "src/[id]/page.tsx"]);
    git_in(&repo, &["commit", "-m", "add bracket route"]);
    let base_sha = git_in(&repo, &["rev-parse", "HEAD"]);

    write_lf(
        &repo.join("src/[id]/page.tsx"),
        "export const useBoth = () => removedAlpha() + removedBeta();\nfunction orphanInternalOne() { return 3; }\nfunction orphanInternalTwo() { return 4; }\n",
    );

    let (c, out, err) = run_b3(&[
        "guard",
        "symbol-check",
        "--repo-root",
        r,
        "--base-sha",
        &base_sha,
    ]);
    assert_eq!(c, 2, "expected SYMBOL_FINDINGS exit 2: {out}\n{err}");
    assert!(out.contains("dangling_refs="), "{out}");
    assert!(out.contains("removedAlpha(1f)"), "{out}");
    assert!(out.contains("removedBeta(1f)"), "{out}");
    assert!(out.contains("orphan_internal="), "{out}");
    assert!(out.contains("src/[id]/page.tsx:orphanInternalOne"), "{out}");
    assert!(out.contains("src/[id]/page.tsx:orphanInternalTwo"), "{out}");
}

#[test]
fn continuous_wave_abcde_release_with_active_and_verified_dirty_scope() {
    let tmp = TempDirGuard::new("cont-wave-abcde");
    let repo = tmp.path.join("repo");
    clone_seeded_git_repo(&repo);
    let r = repo.to_str().unwrap();

    for name in ["a", "b", "c", "d", "e"] {
        write_lf(
            &repo.join(format!("src/{name}.rs")),
            &format!("pub fn {name}() {{}}\n"),
        );
    }
    git_in(&repo, &["add", "."]);
    git_in(&repo, &["commit", "-qm", "seed abcde"]);

    // A + E started; A finished & verified src/a.rs while E is still active editing src/e.rs
    write_lf(&repo.join("src/a.rs"), "pub fn a() -> i32 { 42 }\n");
    write_lf(&repo.join("src/e.rs"), "pub fn e() -> i32 { 99 }\n");

    let (c, out, err) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r,
        "--partition",
        "--max-concurrency",
        "4",
        "--wave-specs",
        "B=src/b.rs;C=src/c.rs;D=src/d.rs",
        "--wave-reads",
        "B=src/a.rs;C=src/a.rs;D=src/a.rs",
        "--active-specs",
        "E=src/e.rs",
        "--verified-dirty-paths",
        "src/a.rs",
        "--check-dirty-scope",
    ]);
    assert_eq!(c, 0, "expected B,C,D parallel release: {out}\n{err}");
    assert!(out.contains("dirty_scope=clean\n"), "{out}");
    assert!(out.contains("unexpected_dirty=none\n"), "{out}");
    assert!(out.contains("active_tasks=E\n"), "{out}");
    assert!(out.contains("active_count=1\n"), "{out}");
    assert!(out.contains("available_slots=3\n"), "{out}");
    assert!(out.contains("active_dirty=src/e.rs\n"), "{out}");
    assert!(out.contains("verified_dirty=src/a.rs\n"), "{out}");
    assert!(out.contains("admitted_tasks=B,C,D\n"), "{out}");
    assert!(out.contains("deferred_tasks=none\n"), "{out}");
    assert!(
        out.contains("wave|1|PARALLEL|agents=3|tasks=B,C,D|reason=independent_ready_tasks\n"),
        "{out}"
    );

    // Candidate X trying to WRITE verified-uncommitted src/a.rs is deferred while B,C proceed
    let (cx, out_x, err_x) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r,
        "--partition",
        "--max-concurrency",
        "4",
        "--wave-specs",
        "X=src/a.rs;B=src/b.rs;C=src/c.rs",
        "--active-specs",
        "E=src/e.rs",
        "--verified-dirty-paths",
        "src/a.rs",
        "--check-dirty-scope",
    ]);
    assert_eq!(
        cx, 0,
        "expected X deferred and B,C admitted: {out_x}\n{err_x}"
    );
    assert!(
        out_x.contains("conflicts=verified_uncommitted:src/a.rs(X)\n"),
        "{out_x}"
    );
    assert!(out_x.contains("admitted_tasks=B,C\n"), "{out_x}");
    assert!(out_x.contains("deferred_tasks=X\n"), "{out_x}");

    // Undeclared dirty file src/rogue.rs fails closed with WAVE_BASE_MISMATCH
    write_lf(&repo.join("src/rogue.rs"), "pub fn rogue() {}\n");
    let (cr, out_r, err_r) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r,
        "--partition",
        "--max-concurrency",
        "4",
        "--wave-specs",
        "B=src/b.rs;C=src/c.rs;D=src/d.rs",
        "--active-specs",
        "E=src/e.rs",
        "--verified-dirty-paths",
        "src/a.rs",
        "--check-dirty-scope",
    ]);
    assert_eq!(
        cr, 2,
        "expected fail-closed unexpected_dirty: {out_r}\n{err_r}"
    );
    assert!(out_r.contains("dirty_scope=unexpected\n"), "{out_r}");
    assert!(out_r.contains("unexpected_dirty=src/rogue.rs\n"), "{out_r}");
    assert!(out_r.contains("admitted_tasks=none\n"), "{out_r}");
    assert!(
        out_r.contains("WAVE_BASE_MISMATCH: unexpected_dirty(src/rogue.rs)"),
        "{out_r}"
    );
}

#[test]
fn continuous_wave_cross_wave_write_conflict_defers_only_conflicting_task() {
    let tmp = TempDirGuard::new("cont-wave-ww");
    let repo = tmp.path.join("repo");
    clone_seeded_git_repo(&repo);
    let r = repo.to_str().unwrap();

    write_lf(&repo.join("src/shared.rs"), "pub fn shared() {}\n");
    write_lf(&repo.join("src/c.rs"), "pub fn c() {}\n");
    write_lf(&repo.join("src/d.rs"), "pub fn d() {}\n");
    git_in(&repo, &["add", "."]);
    git_in(&repo, &["commit", "-qm", "seed ww"]);

    // Active E writes src/shared.rs; B conflicts while C,D are admitted in parallel
    let (c, out, err) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r,
        "--partition",
        "--max-concurrency",
        "4",
        "--wave-specs",
        "B=src/shared.rs;C=src/c.rs;D=src/d.rs",
        "--active-specs",
        "E=src/shared.rs",
    ]);
    assert_eq!(c, 0, "expected partial admission C,D: {out}\n{err}");
    assert!(
        out.contains("conflicts=active:src/shared.rs(E,B)\n"),
        "{out}"
    );
    assert!(out.contains("admitted_tasks=C,D\n"), "{out}");
    assert!(out.contains("deferred_tasks=B\n"), "{out}");
    assert!(
        out.contains("wave|1|PARALLEL|agents=2|tasks=C,D|reason=independent_ready_tasks"),
        "{out}"
    );

    // When ALL candidates conflict with active E -> exit 2 active_worker_conflict
    let (ca, out_a, err_a) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r,
        "--partition",
        "--max-concurrency",
        "4",
        "--wave-specs",
        "B=src/shared.rs",
        "--active-specs",
        "E=src/shared.rs",
    ]);
    assert_eq!(ca, 2, "expected all-conflicting exit 2: {out_a}\n{err_a}");
    assert!(
        out_a.contains("conflicts=active:src/shared.rs(E,B)\n"),
        "{out_a}"
    );
    assert!(out_a.contains("admitted_tasks=none\n"), "{out_a}");
    assert!(out_a.contains("deferred_tasks=B\n"), "{out_a}");
    assert!(
        out_a.contains("WAVE_SEQUENTIAL: waves=0 max_parallel=0 reason=active_worker_conflict"),
        "{out_a}"
    );
}

#[test]
fn continuous_wave_cross_wave_read_write_conflicts_both_directions() {
    let tmp = TempDirGuard::new("cont-wave-rw");
    let repo = tmp.path.join("repo");
    clone_seeded_git_repo(&repo);
    let r = repo.to_str().unwrap();

    for name in ["contract", "e", "b", "c", "d"] {
        write_lf(
            &repo.join(format!("src/{name}.rs")),
            &format!("pub fn {name}() {{}}\n"),
        );
    }
    git_in(&repo, &["add", "."]);
    git_in(&repo, &["commit", "-qm", "seed rw"]);

    // Case 3a: Active E reads src/contract.rs; candidate B writes it while C,D are disjoint
    let (c_a, out_a, err_a) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r,
        "--partition",
        "--max-concurrency",
        "4",
        "--wave-specs",
        "B=src/contract.rs;C=src/c.rs;D=src/d.rs",
        "--active-specs",
        "E=src/e.rs",
        "--active-reads",
        "E=src/contract.rs",
    ]);
    assert_eq!(c_a, 0, "expected B->E active_rw deferral: {out_a}\n{err_a}");
    assert!(
        out_a.contains("conflicts=active_rw:src/contract.rs(B->E)\n"),
        "{out_a}"
    );
    assert!(out_a.contains("admitted_tasks=C,D\n"), "{out_a}");
    assert!(out_a.contains("deferred_tasks=B\n"), "{out_a}");
    assert!(
        out_a.contains("wave|1|PARALLEL|agents=2|tasks=C,D|reason=independent_ready_tasks\n"),
        "{out_a}"
    );

    // Case 3b: Active E writes src/contract.rs; candidate B reads it while C,D are disjoint
    let (c_b, out_b, err_b) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r,
        "--partition",
        "--max-concurrency",
        "4",
        "--wave-specs",
        "B=src/b.rs;C=src/c.rs;D=src/d.rs",
        "--wave-reads",
        "B=src/contract.rs",
        "--active-specs",
        "E=src/contract.rs",
    ]);
    assert_eq!(c_b, 0, "expected E->B active_rw deferral: {out_b}\n{err_b}");
    assert!(
        out_b.contains("conflicts=active_rw:src/contract.rs(E->B)\n"),
        "{out_b}"
    );
    assert!(out_b.contains("admitted_tasks=C,D\n"), "{out_b}");
    assert!(out_b.contains("deferred_tasks=B\n"), "{out_b}");
    assert!(
        out_b.contains("wave|1|PARALLEL|agents=2|tasks=C,D|reason=independent_ready_tasks\n"),
        "{out_b}"
    );
}

#[test]
fn continuous_wave_concurrency_slot_saturation_bounds_admission() {
    let tmp = TempDirGuard::new("cont-wave-slots");
    let repo = tmp.path.join("repo");
    clone_seeded_git_repo(&repo);
    let r = repo.to_str().unwrap();

    for name in ["a", "b", "c", "d", "e"] {
        write_lf(
            &repo.join(format!("src/{name}.rs")),
            &format!("pub fn {name}() {{}}\n"),
        );
    }
    git_in(&repo, &["add", "."]);
    git_in(&repo, &["commit", "-qm", "seed slots"]);

    // Case 4a: --max-concurrency 2 while E is active -> available_slots=1 admits B and defers C,D
    let (c_1, out_1, err_1) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r,
        "--partition",
        "--max-concurrency",
        "2",
        "--wave-specs",
        "B=src/b.rs;C=src/c.rs;D=src/d.rs",
        "--active-specs",
        "E=src/e.rs",
    ]);
    assert_eq!(
        c_1, 0,
        "expected 1-slot bounded admission: {out_1}\n{err_1}"
    );
    assert!(out_1.contains("available_slots=1\n"), "{out_1}");
    assert!(out_1.contains("admitted_tasks=B\n"), "{out_1}");
    assert!(out_1.contains("deferred_tasks=C,D\n"), "{out_1}");
    assert!(
        out_1.contains("wave|1|SEQUENTIAL|agents=1|tasks=B|reason=bounded_concurrency\n"),
        "{out_1}"
    );
    assert!(
        out_1.contains("WAVE_PARTITIONED: waves=2 max_parallel=2"),
        "{out_1}"
    );

    // 2 ready tasks with available_slots=1 + active blocker on C -> concurrency_cap sequential terminal line
    let (c_cap, out_cap, err_cap) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r,
        "--partition",
        "--max-concurrency",
        "2",
        "--wave-specs",
        "B=src/b.rs;C=src/c.rs",
        "--wave-reads",
        "C=src/b.rs",
        "--active-specs",
        "E=src/e.rs",
    ]);
    assert_eq!(
        c_cap, 0,
        "expected concurrency_cap terminal: {out_cap}\n{err_cap}"
    );
    assert!(out_cap.contains("available_slots=1\n"), "{out_cap}");
    assert!(out_cap.contains("admitted_tasks=B\n"), "{out_cap}");
    assert!(out_cap.contains("deferred_tasks=C\n"), "{out_cap}");
    assert!(
        out_cap.contains("WAVE_SEQUENTIAL: waves=2 max_parallel=1 reason=concurrency_cap"),
        "{out_cap}"
    );

    // Case 4b: --max-concurrency 2 while A and E are both active -> available_slots=0 saturated
    let (c_0, out_0, err_0) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r,
        "--partition",
        "--max-concurrency",
        "2",
        "--wave-specs",
        "B=src/b.rs;C=src/c.rs;D=src/d.rs",
        "--active-specs",
        "A=src/a.rs;E=src/e.rs",
    ]);
    assert_eq!(c_0, 2, "expected saturated exit 2: {out_0}\n{err_0}");
    assert!(out_0.contains("active_tasks=A,E\n"), "{out_0}");
    assert!(out_0.contains("active_count=2\n"), "{out_0}");
    assert!(out_0.contains("available_slots=0\n"), "{out_0}");
    assert!(out_0.contains("admitted_tasks=none\n"), "{out_0}");
    assert!(out_0.contains("deferred_tasks=B,C,D\n"), "{out_0}");
    assert!(
        out_0.contains("WAVE_SEQUENTIAL: waves=0 max_parallel=0 reason=concurrency_saturated"),
        "{out_0}"
    );
}

#[test]
fn continuous_wave_duplicate_active_rejection_partial_failure_and_single_slot_fallback() {
    let tmp = TempDirGuard::new("cont-wave-dup-part-seq");
    let repo = tmp.path.join("repo");
    clone_seeded_git_repo(&repo);
    let r = repo.to_str().unwrap();

    for name in ["b", "c", "d", "e"] {
        write_lf(
            &repo.join(format!("src/{name}.rs")),
            &format!("pub fn {name}() {{}}\n"),
        );
    }
    git_in(&repo, &["add", "."]);
    git_in(&repo, &["commit", "-qm", "seed dup-part-seq"]);
    let head = git_in(&repo, &["rev-parse", "HEAD"]);

    // Duplicate active task ID in --wave-specs and --active-specs -> exit 1 WAVE_FAIL
    let (c_dup, _, err_dup) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r,
        "--partition",
        "--wave-specs",
        "E=src/e.rs;B=src/b.rs",
        "--active-specs",
        "E=src/e.rs",
    ]);
    assert_eq!(c_dup, 1, "expected duplicate active task error: {err_dup}");
    assert!(
        err_dup.contains("WAVE_FAIL: duplicate active task 'E'"),
        "{err_dup}"
    );

    // --active-reads without --active-specs -> exit 1 WAVE_FAIL
    let (c_ar, _, err_ar) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r,
        "--partition",
        "--wave-specs",
        "B=src/b.rs",
        "--active-reads",
        "E=src/e.rs",
    ]);
    assert_eq!(c_ar, 1, "expected --active-reads error: {err_ar}");
    assert!(
        err_ar.contains("WAVE_FAIL: --active-reads requires --active-specs"),
        "{err_ar}"
    );

    // Partial failure attribution: D edits src/d.rs while C failed/omitted -> PARTIAL_ATTRIBUTION
    write_lf(&repo.join("src/d.rs"), "pub fn d() -> i32 { 7 }\n");
    let (c_mc, out_mc, err_mc) = run_b3(&[
        "guard",
        "mechanical-check",
        "--repo-root",
        r,
        "--base-sha",
        &head,
        "--allowed-paths",
        "src/c.rs,src/d.rs",
        "--wave-specs",
        "C=src/c.rs;D=src/d.rs",
        "--worker-changes",
        "D=src/d.rs",
    ]);
    assert_eq!(
        c_mc, 2,
        "expected PARTIAL_ATTRIBUTION exit 2: {out_mc}\n{err_mc}"
    );
    assert!(
        out_mc.contains("ownership_verification=PARTIAL_ATTRIBUTION\n"),
        "{out_mc}"
    );
    assert!(
        out_mc.contains("ownership_violations=C(missing_worker)\n"),
        "{out_mc}"
    );
    assert!(out_mc.contains("MECHANICAL_FINDINGS"), "{out_mc}");
    assert_eq!(
        fs::read_to_string(repo.join("src/d.rs")).unwrap(),
        "pub fn d() -> i32 { 7 }\n"
    );

    // Single-slot sequential fallback (--max-concurrency 1 with no active tasks and B,C,D ready)
    let (c_seq, out_seq, err_seq) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r,
        "--partition",
        "--max-concurrency",
        "1",
        "--wave-specs",
        "B=src/b.rs;C=src/c.rs;D=src/d.rs",
    ]);
    assert_eq!(
        c_seq, 0,
        "expected single-slot sequential waves: {out_seq}\n{err_seq}"
    );
    assert!(
        out_seq.contains("wave|1|SEQUENTIAL|agents=1|tasks=B|reason=bounded_concurrency\n"),
        "{out_seq}"
    );
    assert!(
        out_seq.contains("wave|2|SEQUENTIAL|agents=1|tasks=C|reason=bounded_concurrency\n"),
        "{out_seq}"
    );
    assert!(
        out_seq.contains("wave|3|SEQUENTIAL|agents=1|tasks=D|reason=bounded_concurrency\n"),
        "{out_seq}"
    );
    assert!(
        out_seq.contains("WAVE_SEQUENTIAL: waves=3 max_parallel=1 reason=bounded_concurrency"),
        "{out_seq}"
    );

    // Regression guards for ARCH-001/002, SEC-01/02/03, F1/F2/F3:
    // 1. Reject '.' root in --active-specs and --active-reads (even without --partition)
    let (c_dot_as, _, err_dot_as) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r,
        "--wave-specs",
        "B=src/b.rs",
        "--active-specs",
        "E=.",
    ]);
    assert_eq!(
        c_dot_as, 1,
        "expected '.' rejection in --active-specs: {err_dot_as}"
    );
    assert!(err_dot_as.contains("WAVE_FAIL:"), "{err_dot_as}");

    let (c_dot_ar, _, err_dot_ar) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r,
        "--partition",
        "--wave-specs",
        "B=src/b.rs",
        "--active-specs",
        "E=src/e.rs",
        "--active-reads",
        "E=.",
    ]);
    assert_eq!(
        c_dot_ar, 1,
        "expected '.' rejection in --active-reads: {err_dot_ar}"
    );
    assert!(err_dot_ar.contains("WAVE_FAIL:"), "{err_dot_ar}");

    // 2. Allow .b3/* read-only paths in --active-reads (parity with --wave-reads for research-ship Phase E)
    fs::remove_file(repo.join("src/d.rs")).ok();
    git_in(&repo, &["checkout", "--", "src/d.rs"]);
    let (c_b3_ar, out_b3_ar, err_b3_ar) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r,
        "--partition",
        "--wave-specs",
        "V2=none",
        "--wave-reads",
        "V2=.b3/research-ship/runs/r1/evidence-index.md",
        "--active-specs",
        "V1=none",
        "--active-reads",
        "V1=.b3/research-ship/runs/r1/evidence-index.md",
    ]);
    assert_eq!(
        c_b3_ar, 0,
        "--active-reads must allow .b3/* read deps: {out_b3_ar}\n{err_b3_ar}"
    );
    assert!(out_b3_ar.contains("admitted_tasks=V2\n"), "{out_b3_ar}");

    // 3. --verified-dirty-paths auto-runs dirty-scope check even without --check-dirty-scope,
    //    and nested protected paths (e.g. src/.gitmodules) inside directory scopes stay UNEXPECTED_DIRTY
    write_lf(&repo.join("src/b.rs"), "pub fn b() -> i32 { 1 }\n");
    write_lf(&repo.join("src/rogue.rs"), "pub fn rogue() {}\n");
    let (c_auto_dirty, out_auto_dirty, err_auto_dirty) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r,
        "--partition",
        "--wave-specs",
        "C=src/c.rs",
        "--verified-dirty-paths",
        "src/b.rs",
    ]);
    assert_eq!(
        c_auto_dirty, 2,
        "omitting --check-dirty-scope with --verified-dirty-paths must still catch rogue dirty: {out_auto_dirty}\n{err_auto_dirty}"
    );
    assert!(
        format!("{out_auto_dirty}\n{err_auto_dirty}").contains("unexpected_dirty(src/rogue.rs)"),
        "{out_auto_dirty}\n{err_auto_dirty}"
    );
    fs::remove_file(repo.join("src/rogue.rs")).unwrap();

    write_lf(&repo.join("src/.gitmodules"), "[submodule \"x\"]\n");
    let (c_nested_prot, out_nested_prot, err_nested_prot) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r,
        "--partition",
        "--wave-specs",
        "D=docs/guide.md",
        "--active-specs",
        "E=src",
        "--check-dirty-scope",
    ]);
    assert_eq!(
        c_nested_prot, 2,
        "nested protected dirty file inside directory scope must fail closed: {out_nested_prot}\n{err_nested_prot}"
    );
    assert!(
        format!("{out_nested_prot}\n{err_nested_prot}")
            .contains("unexpected_dirty(src/.gitmodules)"),
        "{out_nested_prot}\n{err_nested_prot}"
    );
    fs::remove_file(repo.join("src/.gitmodules")).unwrap();
    git_in(&repo, &["checkout", "--", "src/b.rs"]);

    // 4. F3: when available_slots == 1 and sibling candidate is active_blocked (eligible_now.len() == 1),
    //    wave|1|SEQUENTIAL reports reason=active_worker_conflict rather than vacuous bounded_concurrency
    let (c_f3, out_f3, err_f3) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r,
        "--partition",
        "--max-concurrency",
        "2",
        "--wave-specs",
        "B=src/b.rs;C=src/e.rs",
        "--active-specs",
        "E=src/e.rs",
    ]);
    assert_eq!(
        c_f3, 0,
        "expected B admitted and C active-deferred: {out_f3}\n{err_f3}"
    );
    assert!(
        out_f3.contains("wave|1|SEQUENTIAL|agents=1|tasks=B|reason=active_worker_conflict\n"),
        "{out_f3}"
    );
}

#[test]
fn scoped_autofix_mechanical_boundaries_and_failing_lint_receipt() {
    let tmp = TempDirGuard::new("guard-autofix-mech");
    let repo = tmp.path.join("repo");
    clone_seeded_git_repo(&repo);
    write_lf(&repo.join("src/scoped.ts"), "export const scoped = 1;\n");
    write_lf(&repo.join("src/outside.ts"), "export const outside = 1;\n");
    git_in(&repo, &["add", "."]);
    git_in(&repo, &["commit", "-qm", "seed scoped autofix"]);
    let base = git_in(&repo, &["rev-parse", "HEAD"]);
    let r_str = repo.to_str().unwrap();

    // 1. Clean edit inside allowed-paths passes mechanical-check
    write_lf(
        &repo.join("src/scoped.ts"),
        "export const scoped: number = 2;\n",
    );
    let (ok_c, ok_out, _) = run_b3(&[
        "guard",
        "mechanical-check",
        "--repo-root",
        r_str,
        "--base-sha",
        &base,
        "--allowed-paths",
        "src/scoped.ts",
    ]);
    assert_eq!(ok_c, 0, "{ok_out}");
    assert!(ok_out.contains("MECHANICAL_OK"), "{ok_out}");

    // 2. Out-of-scope edit violates allowed-paths -> scope_creep, exit 2
    write_lf(
        &repo.join("src/outside.ts"),
        "export const outside: number = 2;\n",
    );
    let (sc_c, sc_out, _) = run_b3(&[
        "guard",
        "mechanical-check",
        "--repo-root",
        r_str,
        "--base-sha",
        &base,
        "--allowed-paths",
        "src/scoped.ts",
    ]);
    assert_eq!(sc_c, 2, "{sc_out}");
    assert!(sc_out.contains("MECHANICAL_FINDINGS"), "{sc_out}");
    assert!(sc_out.contains("scope_creep=src/outside.ts"), "{sc_out}");
    git_in(&repo, &["checkout", "--", "src/outside.ts"]);

    // 3. Leftover test isolation marker (only/debug breakpoint) -> leftovers, exit 2
    let marker_only = concat!(".on", "ly(");
    let marker_dbg = concat!("de", "bugger");
    let leftover_body = format!(
        "export const scoped = 2;\nit{marker_only}'isolated', () => {{}});\n{marker_dbg};\n"
    );
    write_lf(&repo.join("src/scoped.ts"), &leftover_body);
    let (lo_c, lo_out, _) = run_b3(&[
        "guard",
        "mechanical-check",
        "--repo-root",
        r_str,
        "--base-sha",
        &base,
        "--allowed-paths",
        "src/scoped.ts",
    ]);
    assert_eq!(lo_c, 2, "{lo_out}");
    assert!(lo_out.contains("MECHANICAL_FINDINGS"), "{lo_out}");
    assert!(
        lo_out.contains("leftovers=") && !lo_out.contains("leftovers=none"),
        "{lo_out}"
    );
    assert!(lo_out.contains(marker_only), "{lo_out}");
    assert!(lo_out.contains(marker_dbg), "{lo_out}");

    // Restore clean scoped edit and confirm failing lint command records failure & fails verify-check
    write_lf(
        &repo.join("src/scoped.ts"),
        "export const scoped: number = 2;\n",
    );
    let fail_lint_cmd = verify_cmd_fail(2, "lint error: unused import");
    let receipt_rel = ".b3/ship/verify/lint-fail.verify";
    let (vr_c, vr_out, _) = run_b3(&[
        "guard",
        "verify-run",
        "--repo-root",
        r_str,
        "--task-id",
        "T1",
        "--verify-cmd",
        &fail_lint_cmd,
        "--receipt-path",
        receipt_rel,
        "--relevant-paths",
        "src/scoped.ts",
    ]);
    assert_eq!(vr_c, 1, "failing lint verify-run must exit 1: {vr_out}");
    assert!(vr_out.contains("VERIFY_FAIL: exit=2"), "{vr_out}");

    let (vc_c, vc_out, _) = run_b3(&[
        "guard",
        "verify-check",
        "--repo-root",
        r_str,
        "--receipt-path",
        receipt_rel,
        "--expected-cmd",
        &fail_lint_cmd,
    ]);
    assert_ne!(
        vc_c, 0,
        "verify-check must reject failed lint receipt: {vc_out}"
    );
    assert!(
        vc_out.contains("VERIFY_FAILED_RECEIPT: exit=2 status=FAIL"),
        "{vc_out}"
    );
}

#[test]
fn no_lint_symbol_check_deterministic_fallback_dangling_and_advisory() {
    let tmp = TempDirGuard::new("guard-sym-fallback");
    let repo = tmp.path.join("repo");
    clone_seeded_git_repo(&repo);
    write_lf(
        &repo.join("src/provider.ts"),
        "export function helperApi() { return 1; }\nexport function keepApi() { return 2; }\n",
    );
    write_lf(
        &repo.join("src/consumer.ts"),
        "import { helperApi } from './provider';\nexport const result = helperApi();\n",
    );
    git_in(&repo, &["add", "."]);
    git_in(&repo, &["commit", "-qm", "seed symbol fallback"]);
    let base = git_in(&repo, &["rev-parse", "HEAD"]);
    let r_str = repo.to_str().unwrap();

    // 1. Introducing an unused internal symbol reports SYMBOL_ADVISORY cleanly (exit 0)
    write_lf(
        &repo.join("src/provider.ts"),
        "export function helperApi() { return 1; }\nexport function keepApi() { return 2; }\nfunction internalUnused() { return 9; }\n",
    );
    let (adv_c, adv_out, _) = run_b3(&[
        "guard",
        "symbol-check",
        "--repo-root",
        r_str,
        "--base-sha",
        &base,
    ]);
    assert_eq!(adv_c, 0, "unused internal symbol must exit 0: {adv_out}");
    assert!(adv_out.contains("SYMBOL_ADVISORY"), "{adv_out}");
    assert!(adv_out.contains("dangling_refs=none"), "{adv_out}");
    assert!(
        adv_out.contains("orphan_internal=src/provider.ts:internalUnused"),
        "{adv_out}"
    );

    // 2. Deleting a symbol still referenced elsewhere exits 2 with dangling_refs
    write_lf(
        &repo.join("src/provider.ts"),
        "export function keepApi() { return 2; }\n",
    );
    let (dan_c, dan_out, _) = run_b3(&[
        "guard",
        "symbol-check",
        "--repo-root",
        r_str,
        "--base-sha",
        &base,
    ]);
    assert_eq!(dan_c, 2, "dangling ref must exit 2: {dan_out}");
    assert!(dan_out.contains("SYMBOL_FINDINGS"), "{dan_out}");
    assert!(dan_out.contains("exported_removed=helperApi"), "{dan_out}");
    assert!(dan_out.contains("dangling_refs=helperApi(1f)"), "{dan_out}");
}

#[test]
fn wave_partition_blocks_shared_write_paths_and_allows_disjoint_writes() {
    let tmp = TempDirGuard::new("guard-wave-partition");
    let repo = tmp.path.join("repo");
    clone_seeded_git_repo(&repo);
    write_lf(&repo.join("eslint.config.mjs"), "export default [];\n");
    write_lf(&repo.join("src/a.ts"), "export const a = 1;\n");
    write_lf(&repo.join("src/b.ts"), "export const b = 1;\n");
    write_lf(&repo.join("src/c.ts"), "export const c = 1;\n");
    git_in(&repo, &["add", "."]);
    git_in(&repo, &["commit", "-qm", "seed wave partition"]);
    let head = git_in(&repo, &["rev-parse", "HEAD"]);
    let r_str = repo.to_str().unwrap();

    // 1. Disjoint write paths allow parallel admission
    let (ok_c, ok_out, _) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r_str,
        "--partition",
        "--expected-base-sha",
        &head,
        "--wave-specs",
        "T1=src/a.ts;T2=src/b.ts",
    ]);
    assert_eq!(ok_c, 0, "{ok_out}");
    assert!(ok_out.contains("conflicts=none"), "{ok_out}");
    assert!(
        ok_out.contains("WAVE_OK: disjoint (2 tasks, 2 paths)"),
        "{ok_out}"
    );

    // 2. Two workers sharing writable manifest/auto-fix path cannot run in parallel
    let (seq_c, seq_out, _) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r_str,
        "--partition",
        "--expected-base-sha",
        &head,
        "--wave-specs",
        "T1=eslint.config.mjs,src/a.ts;T2=eslint.config.mjs,src/b.ts",
    ]);
    assert_eq!(seq_c, 2, "{seq_out}");
    assert!(
        seq_out.contains("conflicts=eslint.config.mjs(T1,T2)"),
        "{seq_out}"
    );
    assert!(seq_out.contains("max_parallel=1"), "{seq_out}");
    assert!(
        seq_out.contains("wave|1|SEQUENTIAL|agents=1|tasks=T1|reason=shared_write_conflict"),
        "{seq_out}"
    );
    assert!(
        seq_out.contains("wave|2|SEQUENTIAL|agents=1|tasks=T2|reason=shared_write_conflict"),
        "{seq_out}"
    );
    assert!(
        seq_out.contains("WAVE_SEQUENTIAL: waves=2 max_parallel=1 reason=shared_write_conflict"),
        "{seq_out}"
    );

    // 3. Conflicting pair splits into sequential wave while disjoint T3 runs in parallel wave 1
    let (part_c, part_out, _) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r_str,
        "--partition",
        "--expected-base-sha",
        &head,
        "--wave-specs",
        "T1=eslint.config.mjs,src/a.ts;T2=eslint.config.mjs,src/b.ts;T3=src/c.ts",
    ]);
    assert_eq!(part_c, 0, "{part_out}");
    assert!(
        part_out.contains("conflicts=eslint.config.mjs(T1,T2)"),
        "{part_out}"
    );
    assert!(
        part_out.contains("wave|1|PARALLEL|agents=2|tasks=T1,T3|reason=independent_ready_tasks"),
        "{part_out}"
    );
    assert!(
        part_out.contains("wave|2|SEQUENTIAL|agents=1|tasks=T2|reason=shared_write_conflict"),
        "{part_out}"
    );
    assert!(
        part_out.contains("WAVE_PARTITIONED: waves=2 max_parallel=2 reason=conflicting_wave_split"),
        "{part_out}"
    );

    // 4. Continuous active-worker mode defers conflicting T2 while admitting disjoint T3
    let (act_c, act_out, _) = run_b3(&[
        "guard",
        "check-wave",
        "--repo-root",
        r_str,
        "--partition",
        "--expected-base-sha",
        &head,
        "--active-specs",
        "T1=eslint.config.mjs,src/a.ts",
        "--wave-specs",
        "T2=eslint.config.mjs,src/b.ts;T3=src/c.ts",
    ]);
    assert_eq!(act_c, 0, "{act_out}");
    assert!(act_out.contains("admitted_tasks=T3\n"), "{act_out}");
    assert!(act_out.contains("deferred_tasks=T2\n"), "{act_out}");
}
