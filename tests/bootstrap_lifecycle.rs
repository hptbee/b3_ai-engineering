//! Cross-platform lifecycle and security tests for `scripts/bootstrap-b3.{ps1,sh}`.
//! Runs PowerShell on Windows and `bash` on Unix with zero PowerShell dependency on Unix.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

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
            "b3-boot-test-{prefix}-{}-{seq}",
            std::process::id()
        ));
        if dir.exists() {
            Self::remove_tree(&dir);
        }
        fs::create_dir_all(&dir).expect("create temp dir");
        Self { path: dir }
    }

    fn remove_tree(dir: &Path) {
        #[cfg(windows)]
        {
            let _ = Command::new("cmd")
                .args([
                    "/d",
                    "/c",
                    &format!(
                        "for /d %d in (\"{}\") do @rmdir /s /q \"%d\" 2>nul",
                        dir.display()
                    ),
                ])
                .status();
        }
        let _ = fs::remove_dir_all(dir);
    }
}

impl Drop for TempDirGuard {
    fn drop(&mut self) {
        Self::remove_tree(&self.path);
    }
}

fn norm_lf(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes)
        .replace("\r\n", "\n")
        .trim_end_matches('\n')
        .to_string()
}

fn sha256_file_hex(path: &Path) -> String {
    let bytes = fs::read(path).expect("read file for sha256");
    b3::fs::sha256_bytes_hex(&bytes)
}

fn host_target_and_names() -> (&'static str, &'static str, &'static str) {
    if cfg!(windows) {
        (
            "x86_64-pc-windows-msvc",
            "b3-x86_64-pc-windows-msvc.exe",
            "b3.exe",
        )
    } else if cfg!(target_os = "macos") && cfg!(target_arch = "aarch64") {
        ("aarch64-apple-darwin", "b3-aarch64-apple-darwin", "b3")
    } else if cfg!(target_os = "macos") {
        ("x86_64-apple-darwin", "b3-x86_64-apple-darwin", "b3")
    } else {
        (
            "x86_64-unknown-linux-gnu",
            "b3-x86_64-unknown-linux-gnu",
            "b3",
        )
    }
}

fn run_bootstrap(args: &[&str]) -> (i32, String, String) {
    let root = repo_root();
    #[cfg(windows)]
    {
        let script = root.join("scripts/bootstrap-b3.ps1");
        let out = Command::new("powershell")
            .arg("-NoProfile")
            .arg("-ExecutionPolicy")
            .arg("Bypass")
            .arg("-File")
            .arg(&script)
            .args(args)
            .output()
            .expect("run bootstrap-b3.ps1");
        (
            out.status.code().unwrap_or(-1),
            norm_lf(&out.stdout),
            norm_lf(&out.stderr),
        )
    }
    #[cfg(not(windows))]
    {
        let script = root.join("scripts/bootstrap-b3.sh");
        let out = Command::new("bash")
            .arg(&script)
            .args(args)
            .output()
            .expect("run bootstrap-b3.sh");
        (
            out.status.code().unwrap_or(-1),
            norm_lf(&out.stdout),
            norm_lf(&out.stderr),
        )
    }
}

fn flag_name(win: &'static str, unix: &'static str) -> &'static str {
    if cfg!(windows) {
        win
    } else {
        unix
    }
}

fn make_release_dir(dir: &Path, artifact_name: &str, bytes: &[u8]) -> String {
    fs::create_dir_all(dir).expect("create release dir");
    let art = dir.join(artifact_name);
    fs::write(&art, bytes).expect("write release artifact");
    let sha = b3::fs::sha256_bytes_hex(bytes);
    fs::write(
        dir.join("SHA256SUMS.txt"),
        format!("{sha}  {artifact_name}\n"),
    )
    .expect("write SHA256SUMS.txt");
    sha
}

fn write_prior_valid_binary_bytes() -> Vec<u8> {
    #[cfg(unix)]
    {
        b"#!/bin/sh\nif [ \"${1:-}\" = \"--version\" ]; then echo \"b3 0.0.9-prior\"; exit 0; fi\nsleep 5\n".to_vec()
    }
    #[cfg(windows)]
    {
        let mut data = fs::read(b3_bin()).expect("read b3.exe");
        data.extend_from_slice(b"\0B3PRIOR00000001\0");
        data
    }
}

fn create_dir_link(link: &Path, target: &Path) {
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(target, link).expect("create unix dir symlink");
    }
    #[cfg(windows)]
    {
        let status = Command::new("cmd")
            .args([
                "/d",
                "/c",
                "mklink",
                "/J",
                link.to_str().unwrap(),
                target.to_str().unwrap(),
            ])
            .status()
            .expect("invoke mklink /J");
        assert!(status.success(), "mklink /J failed for {}", link.display());
    }
}

#[test]
fn bootstrap_fresh_install_and_dry_run_no_mutations() {
    let rel_tmp = TempDirGuard::new("fresh-rel");
    let inst_base = TempDirGuard::new("fresh-inst");
    let inst_dir = inst_base.path.join("nested").join("bin");
    let (target, artifact_name, dest_name) = host_target_and_names();

    let b3_bytes = fs::read(b3_bin()).expect("read b3 bin");
    let expected_sha = make_release_dir(&rel_tmp.path, artifact_name, &b3_bytes);

    let rel_s = rel_tmp.path.to_str().unwrap();
    let inst_s = inst_dir.to_str().unwrap();
    let f_rel = flag_name("-ReleaseDir", "--release-dir");
    let f_inst = flag_name("-InstallDir", "--install-dir");
    let f_tgt = flag_name("-Target", "--target");
    let f_dry = flag_name("-DryRun", "--dry-run");
    let f_rb = flag_name("-Rollback", "--rollback");

    // 1. Dry-run on non-existent InstallDir must succeed and perform ZERO mutations.
    let (dc, dout, derr) = run_bootstrap(&[f_rel, rel_s, f_inst, inst_s, f_tgt, target, f_dry]);
    assert_eq!(dc, 0, "dry-run failed:\n{dout}\n{derr}");
    assert!(dout.contains("DRY_RUN:"), "dout={dout}");
    assert!(
        !inst_base.path.join("nested").exists(),
        "dry-run mutated FS"
    );

    // 2. Fresh install creates InstallDir, verifies checksum & smoke check, leaves no lock.
    let (ic, iout, ierr) = run_bootstrap(&[f_rel, rel_s, f_inst, inst_s, f_tgt, target]);
    assert_eq!(ic, 0, "fresh install failed:\n{iout}\n{ierr}");
    assert!(iout.contains("BOOTSTRAP_OK:"), "iout={iout}");

    let dest_bin = inst_dir.join(dest_name);
    assert!(dest_bin.is_file());
    assert_eq!(sha256_file_hex(&dest_bin), expected_sha);
    assert!(!inst_dir.join(".b3-bootstrap.lock").exists());

    // 3. Dry-run rollback after seeding a valid .prev leaves active binary untouched.
    let prior_bytes = write_prior_valid_binary_bytes();
    let prior_sha = make_release_dir(&rel_tmp.path.join("prior"), artifact_name, &prior_bytes);
    let rel_prior_s = rel_tmp.path.join("prior").to_str().unwrap().to_string();
    let (uc, uout, uerr) = run_bootstrap(&[f_rel, &rel_prior_s, f_inst, inst_s, f_tgt, target]);
    assert_eq!(uc, 0, "upgrade failed:\n{uout}\n{uerr}");
    assert_eq!(sha256_file_hex(&dest_bin), prior_sha);

    let (rdc, rdout, rderr) = run_bootstrap(&[f_inst, inst_s, f_tgt, target, f_rb, f_dry]);
    assert_eq!(rdc, 0, "rollback dry-run failed:\n{rdout}\n{rderr}");
    assert!(rdout.contains("DRY_RUN:"), "rdout={rdout}");
    assert_eq!(sha256_file_hex(&dest_bin), prior_sha);
}

#[test]
fn bootstrap_valid_upgrade_over_in_use_binary_and_idempotent_rollback() {
    let rel_prior = TempDirGuard::new("inuse-prior-rel");
    let rel_new = TempDirGuard::new("inuse-new-rel");
    let inst_tmp = TempDirGuard::new("inuse-inst");
    let (target, artifact_name, dest_name) = host_target_and_names();

    let prior_bytes = write_prior_valid_binary_bytes();
    let new_bytes = fs::read(b3_bin()).expect("read b3 bin");
    let prior_sha = make_release_dir(&rel_prior.path, artifact_name, &prior_bytes);
    let new_sha = make_release_dir(&rel_new.path, artifact_name, &new_bytes);
    assert_ne!(prior_sha, new_sha, "prior and new binaries must differ");

    let inst_s = inst_tmp.path.to_str().unwrap();
    let f_rel = flag_name("-ReleaseDir", "--release-dir");
    let f_inst = flag_name("-InstallDir", "--install-dir");
    let f_tgt = flag_name("-Target", "--target");
    let f_rb = flag_name("-Rollback", "--rollback");

    // Install prior binary cleanly.
    let (c1, o1, e1) = run_bootstrap(&[
        f_rel,
        rel_prior.path.to_str().unwrap(),
        f_inst,
        inst_s,
        f_tgt,
        target,
    ]);
    assert_eq!(c1, 0, "prior install failed:\n{o1}\n{e1}");
    let dest_bin = inst_tmp.path.join(dest_name);
    let prev_bin = inst_tmp.path.join(format!("{dest_name}.prev"));
    assert_eq!(sha256_file_hex(&dest_bin), prior_sha);

    // Hold dest_bin actively running in a child process during upgrade.
    let git_tmp = TempDirGuard::new("inuse-git");
    #[cfg(windows)]
    {
        fs::create_dir_all(git_tmp.path.join(".b3")).expect("create .b3 dir");
        let init = Command::new("git")
            .args(["-C", git_tmp.path.to_str().unwrap(), "init"])
            .status()
            .expect("git init");
        assert!(init.success());
        let commit = Command::new("git")
            .args([
                "-C",
                git_tmp.path.to_str().unwrap(),
                "-c",
                "user.name=t",
                "-c",
                "user.email=t@t",
                "commit",
                "--allow-empty",
                "-m",
                "init",
            ])
            .status()
            .expect("git commit");
        assert!(commit.success());
    }

    let mut child = {
        #[cfg(windows)]
        {
            let receipt = git_tmp.path.join(".b3").join("verify.json");
            Command::new(&dest_bin)
                .args([
                    "guard",
                    "verify-run",
                    "--repo-root",
                    git_tmp.path.to_str().unwrap(),
                    "--verify-cmd",
                    "powershell -NoProfile -Command Start-Sleep -Seconds 5",
                    "--receipt-path",
                    receipt.to_str().unwrap(),
                ])
                .spawn()
                .expect("spawn running b3.exe")
        }
        #[cfg(unix)]
        {
            let _ = &git_tmp;
            Command::new(&dest_bin)
                .arg("hold")
                .spawn()
                .expect("spawn running prior script")
        }
    };

    thread::sleep(Duration::from_millis(250));
    assert!(
        child.try_wait().expect("poll child").is_none(),
        "in-use child exited prematurely before upgrade test"
    );

    let (c2, o2, e2) = run_bootstrap(&[
        f_rel,
        rel_new.path.to_str().unwrap(),
        f_inst,
        inst_s,
        f_tgt,
        target,
    ]);

    let _ = child.kill();
    let _ = child.wait();

    assert_eq!(c2, 0, "in-use upgrade failed:\n{o2}\n{e2}");
    assert!(o2.contains("BOOTSTRAP_OK:"), "o2={o2}");
    assert_eq!(sha256_file_hex(&dest_bin), new_sha);
    assert_eq!(sha256_file_hex(&prev_bin), prior_sha);

    // Idempotent rollback (two consecutive invocations produce identical result).
    for pass in 1..=2 {
        let (rc, ro, re) = run_bootstrap(&[f_inst, inst_s, f_tgt, target, f_rb]);
        assert_eq!(rc, 0, "rollback pass {pass} failed:\n{ro}\n{re}");
        assert!(ro.contains("ROLLBACK_OK:"), "ro={ro}");
        assert_eq!(sha256_file_hex(&dest_bin), prior_sha);
        assert_eq!(sha256_file_hex(&prev_bin), prior_sha);
    }

    // Missing .prev and invalid .prev must both fail cleanly.
    fs::write(&prev_bin, b"CORRUPT_NOT_A_BINARY").unwrap();
    let (bc, bo, be) = run_bootstrap(&[f_inst, inst_s, f_tgt, target, f_rb]);
    assert_ne!(bc, 0, "invalid .prev rollback must fail:\n{bo}\n{be}");
    assert!(be.contains("ROLLBACK_FAIL:"), "be={be}");
    assert_eq!(sha256_file_hex(&dest_bin), prior_sha);

    fs::remove_file(&prev_bin).unwrap();
    let (mc, mo, me) = run_bootstrap(&[f_inst, inst_s, f_tgt, target, f_rb]);
    assert_ne!(mc, 0, "missing .prev rollback must fail:\n{mo}\n{me}");
    assert!(me.contains("ROLLBACK_FAIL:"), "me={me}");
    assert_eq!(sha256_file_hex(&dest_bin), prior_sha);
}

#[test]
fn bootstrap_rejects_bad_checksum_malformed_ambiguous_missing_and_invalid_inputs() {
    let rel_tmp = TempDirGuard::new("bad-rel");
    let inst_tmp = TempDirGuard::new("bad-inst");
    let (target, artifact_name, dest_name) = host_target_and_names();

    let b3_bytes = fs::read(b3_bin()).expect("read b3 bin");
    let real_sha = make_release_dir(&rel_tmp.path, artifact_name, &b3_bytes);
    let dest_bin = inst_tmp.path.join(dest_name);
    fs::write(&dest_bin, b"ACTIVE_BINARY_SENTINEL").unwrap();
    let active_sha = sha256_file_hex(&dest_bin);

    let rel_s = rel_tmp.path.to_str().unwrap();
    let inst_s = inst_tmp.path.to_str().unwrap();
    let f_rel = flag_name("-ReleaseDir", "--release-dir");
    let f_inst = flag_name("-InstallDir", "--install-dir");
    let f_tgt = flag_name("-Target", "--target");
    let f_repo = flag_name("-Repo", "--repo");
    let f_ver = flag_name("-Version", "--version");

    // 1. Mismatched checksum
    fs::write(
        rel_tmp.path.join("SHA256SUMS.txt"),
        format!("{}  {artifact_name}\n", "0".repeat(64)),
    )
    .unwrap();
    let (c, _, e) = run_bootstrap(&[f_rel, rel_s, f_inst, inst_s, f_tgt, target]);
    assert_ne!(c, 0);
    assert!(e.contains("BOOTSTRAP_FAIL:"), "e={e}");
    assert_eq!(sha256_file_hex(&dest_bin), active_sha);

    // 2. Malformed SHA256SUMS.txt (extra garbage line)
    fs::write(
        rel_tmp.path.join("SHA256SUMS.txt"),
        format!("{real_sha}  {artifact_name}\nnot_a_valid_line_here\n"),
    )
    .unwrap();
    let (c, _, e) = run_bootstrap(&[f_rel, rel_s, f_inst, inst_s, f_tgt, target]);
    assert_ne!(c, 0);
    assert!(e.contains("BOOTSTRAP_FAIL:"), "e={e}");
    assert_eq!(sha256_file_hex(&dest_bin), active_sha);

    // 3. Duplicate/ambiguous entries for the same normalized artifact
    fs::write(
        rel_tmp.path.join("SHA256SUMS.txt"),
        format!("{real_sha}  {artifact_name}\n{real_sha}  ./{artifact_name}\n"),
    )
    .unwrap();
    let (c, _, e) = run_bootstrap(&[f_rel, rel_s, f_inst, inst_s, f_tgt, target]);
    assert_ne!(c, 0);
    assert!(e.contains("BOOTSTRAP_FAIL:"), "e={e}");
    assert_eq!(sha256_file_hex(&dest_bin), active_sha);

    // 4. Blank manifest
    fs::write(rel_tmp.path.join("SHA256SUMS.txt"), "\n  \n").unwrap();
    let (c, _, e) = run_bootstrap(&[f_rel, rel_s, f_inst, inst_s, f_tgt, target]);
    assert_ne!(c, 0);
    assert!(e.contains("BOOTSTRAP_FAIL:"), "e={e}");
    assert_eq!(sha256_file_hex(&dest_bin), active_sha);

    // Restore valid manifest, then remove artifact.
    fs::write(
        rel_tmp.path.join("SHA256SUMS.txt"),
        format!("{real_sha}  {artifact_name}\n"),
    )
    .unwrap();
    fs::remove_file(rel_tmp.path.join(artifact_name)).unwrap();
    let (c, _, e) = run_bootstrap(&[f_rel, rel_s, f_inst, inst_s, f_tgt, target]);
    assert_ne!(c, 0);
    assert!(e.contains("BOOTSTRAP_FAIL:"), "e={e}");
    assert_eq!(sha256_file_hex(&dest_bin), active_sha);

    // Restore artifact, test invalid inputs.
    fs::write(rel_tmp.path.join(artifact_name), &b3_bytes).unwrap();

    for bad_tgt in ["sparc64-unknown-solaris", "../evil"] {
        let (c, _, e) = run_bootstrap(&[f_rel, rel_s, f_inst, inst_s, f_tgt, bad_tgt]);
        assert_ne!(c, 0, "bad target {bad_tgt} must fail");
        assert!(e.contains("BOOTSTRAP_FAIL:"), "e={e}");
    }
    for bad_repo in ["../evil", "no-slash", "a/b/c", "./repo"] {
        let (c, _, e) = run_bootstrap(&[
            f_rel, rel_s, f_inst, inst_s, f_tgt, target, f_repo, bad_repo,
        ]);
        assert_ne!(c, 0, "bad repo {bad_repo} must fail");
        assert!(e.contains("BOOTSTRAP_FAIL:"), "e={e}");
    }
    for bad_ver in ["v1/../x", "not-a-tag", "v1.2.3?q=1", "v1.0.0-.."] {
        let (c, _, e) =
            run_bootstrap(&[f_rel, rel_s, f_inst, inst_s, f_tgt, target, f_ver, bad_ver]);
        assert_ne!(c, 0, "bad version {bad_ver} must fail");
        assert!(e.contains("BOOTSTRAP_FAIL:"), "e={e}");
    }
    for bad_inst in ["../evil", "   "] {
        let (c, _, e) = run_bootstrap(&[f_rel, rel_s, f_inst, bad_inst, f_tgt, target]);
        assert_ne!(c, 0, "bad install dir {bad_inst:?} must fail");
        assert!(e.contains("BOOTSTRAP_FAIL:"), "e={e}");
    }
    assert_eq!(sha256_file_hex(&dest_bin), active_sha);
}

#[test]
fn bootstrap_failed_smoke_test_preserves_active_and_prev() {
    let rel_tmp = TempDirGuard::new("smoke-rel");
    let inst_tmp = TempDirGuard::new("smoke-inst");
    let (target, artifact_name, dest_name) = host_target_and_names();

    let bad_payload: &[u8] = if cfg!(windows) {
        b"MZ\x00\x00NOT_A_VALID_PE_IMAGE"
    } else {
        b"#!/bin/sh\necho bad-version-output\n"
    };
    make_release_dir(&rel_tmp.path, artifact_name, bad_payload);

    let dest_bin = inst_tmp.path.join(dest_name);
    let prev_bin = inst_tmp.path.join(format!("{dest_name}.prev"));
    fs::write(&dest_bin, b"ACTIVE_GOOD_SENTINEL").unwrap();
    fs::write(&prev_bin, b"PREV_GOOD_SENTINEL").unwrap();

    let f_rel = flag_name("-ReleaseDir", "--release-dir");
    let f_inst = flag_name("-InstallDir", "--install-dir");
    let f_tgt = flag_name("-Target", "--target");

    let (c, o, e) = run_bootstrap(&[
        f_rel,
        rel_tmp.path.to_str().unwrap(),
        f_inst,
        inst_tmp.path.to_str().unwrap(),
        f_tgt,
        target,
    ]);
    assert_ne!(c, 0, "smoke failure must abort:\n{o}\n{e}");
    assert!(e.contains("BOOTSTRAP_FAIL:"), "e={e}");
    assert_eq!(fs::read(&dest_bin).unwrap(), b"ACTIVE_GOOD_SENTINEL");
    assert_eq!(fs::read(&prev_bin).unwrap(), b"PREV_GOOD_SENTINEL");

    // Ensure no leftover staged temp files remain in InstallDir.
    let entries: Vec<String> = fs::read_dir(&inst_tmp.path)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    assert!(
        !entries.iter().any(|n| n.contains(".new.")),
        "leftover staged file found: {entries:?}"
    );
}

#[test]
fn bootstrap_rejects_symlink_and_junction_destination_and_ancestor() {
    let rel_tmp = TempDirGuard::new("link-rel");
    let ext_tmp = TempDirGuard::new("link-ext");
    let host_tmp = TempDirGuard::new("link-host");
    let (target, artifact_name, dest_name) = host_target_and_names();

    let b3_bytes = fs::read(b3_bin()).expect("read b3 bin");
    make_release_dir(&rel_tmp.path, artifact_name, &b3_bytes);
    fs::write(ext_tmp.path.join("sentinel.txt"), "untouched\n").unwrap();
    let ext_file = ext_tmp.path.join("target_file");
    fs::write(&ext_file, "untouched\n").unwrap();

    let f_rel = flag_name("-ReleaseDir", "--release-dir");
    let f_inst = flag_name("-InstallDir", "--install-dir");
    let f_tgt = flag_name("-Target", "--target");
    let f_rb = flag_name("-Rollback", "--rollback");
    let rel_s = rel_tmp.path.to_str().unwrap();

    // 1. Link as ancestor directory (parent/link/bin)
    let anc_link = host_tmp.path.join("anc_link");
    create_dir_link(&anc_link, &ext_tmp.path);
    let anc_inst = anc_link.join("bin");
    let (c, _, e) = run_bootstrap(&[
        f_rel,
        rel_s,
        f_inst,
        anc_inst.to_str().unwrap(),
        f_tgt,
        target,
    ]);
    assert_ne!(c, 0, "ancestor link must be rejected");
    assert!(e.contains("BOOTSTRAP_FAIL:"), "e={e}");
    assert!(!ext_tmp.path.join("bin").exists());

    // 2. Link as InstallDir itself
    let inst_link = host_tmp.path.join("inst_link");
    create_dir_link(&inst_link, &ext_tmp.path);
    let (c, _, e) = run_bootstrap(&[
        f_rel,
        rel_s,
        f_inst,
        inst_link.to_str().unwrap(),
        f_tgt,
        target,
    ]);
    assert_ne!(c, 0, "link InstallDir must be rejected");
    assert!(e.contains("BOOTSTRAP_FAIL:"), "e={e}");

    // 3. Link as dest_bin and .prev
    let dir_case = host_tmp.path.join("dir_case");
    fs::create_dir_all(&dir_case).unwrap();
    let dest_link = dir_case.join(dest_name);
    #[cfg(unix)]
    std::os::unix::fs::symlink(&ext_file, &dest_link).unwrap();
    #[cfg(windows)]
    create_dir_link(&dest_link, &ext_tmp.path);
    let (c, _, e) = run_bootstrap(&[
        f_rel,
        rel_s,
        f_inst,
        dir_case.to_str().unwrap(),
        f_tgt,
        target,
    ]);
    assert_ne!(c, 0, "link dest_bin must be rejected");
    assert!(e.contains("BOOTSTRAP_FAIL:"), "e={e}");
    let (rc, _, re) = run_bootstrap(&[f_inst, dir_case.to_str().unwrap(), f_tgt, target, f_rb]);
    assert_ne!(rc, 0, "rollback over link dest_bin must be rejected");
    assert!(re.contains("BOOTSTRAP_FAIL:"), "re={re}");

    let prev_case = host_tmp.path.join("prev_case");
    fs::create_dir_all(&prev_case).unwrap();
    let prev_link = prev_case.join(format!("{dest_name}.prev"));
    #[cfg(unix)]
    std::os::unix::fs::symlink(&ext_file, &prev_link).unwrap();
    #[cfg(windows)]
    create_dir_link(&prev_link, &ext_tmp.path);
    let (c, _, e) = run_bootstrap(&[
        f_rel,
        rel_s,
        f_inst,
        prev_case.to_str().unwrap(),
        f_tgt,
        target,
    ]);
    assert_ne!(c, 0, "link .prev must be rejected");
    assert!(e.contains("BOOTSTRAP_FAIL:"), "e={e}");

    assert_eq!(
        fs::read_to_string(ext_tmp.path.join("sentinel.txt")).unwrap(),
        "untouched\n"
    );
}

#[test]
fn bootstrap_concurrent_installs_no_corruption() {
    let rel_tmp = TempDirGuard::new("conc-rel");
    let inst_tmp = TempDirGuard::new("conc-inst");
    let (target, artifact_name, dest_name) = host_target_and_names();

    let b3_bytes = fs::read(b3_bin()).expect("read b3 bin");
    let expected_sha = make_release_dir(&rel_tmp.path, artifact_name, &b3_bytes);

    let rel_s = Arc::new(rel_tmp.path.to_string_lossy().into_owned());
    let inst_s = Arc::new(inst_tmp.path.to_string_lossy().into_owned());

    let mut handles = Vec::new();
    for _ in 0..2 {
        let rel_c = Arc::clone(&rel_s);
        let inst_c = Arc::clone(&inst_s);
        handles.push(thread::spawn(move || {
            let f_rel = flag_name("-ReleaseDir", "--release-dir");
            let f_inst = flag_name("-InstallDir", "--install-dir");
            let f_tgt = flag_name("-Target", "--target");
            run_bootstrap(&[f_rel, &rel_c, f_inst, &inst_c, f_tgt, target])
        }));
    }

    let results: Vec<(i32, String, String)> =
        handles.into_iter().map(|h| h.join().unwrap()).collect();
    let ok_count = results.iter().filter(|(c, _, _)| *c == 0).count();
    assert!(
        ok_count >= 1,
        "at least one concurrent install must succeed: {results:?}"
    );
    for (c, o, e) in &results {
        if *c == 0 {
            assert!(o.contains("BOOTSTRAP_OK:"), "o={o}");
        } else {
            assert!(
                e.contains("concurrent bootstrap"),
                "unexpected failure in concurrent install: c={c} o={o} e={e}"
            );
        }
    }

    let dest_bin = inst_tmp.path.join(dest_name);
    assert!(dest_bin.is_file());
    assert_eq!(sha256_file_hex(&dest_bin), expected_sha);
    let ver = Command::new(&dest_bin)
        .arg("--version")
        .output()
        .expect("run installed b3 --version");
    assert!(ver.status.success());
    assert!(norm_lf(&ver.stdout).starts_with("b3 "));
    assert!(!inst_tmp.path.join(".b3-bootstrap.lock").exists());
}
