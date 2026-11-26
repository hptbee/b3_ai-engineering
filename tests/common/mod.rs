#![allow(dead_code)]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::OnceLock;

static COMMON_SEQ: AtomicU64 = AtomicU64::new(0);
static SEED_REPO: OnceLock<(PathBuf, String)> = OnceLock::new();

pub fn b3_bin() -> &'static str {
    env!("CARGO_BIN_EXE_b3")
}

pub fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

pub struct TempDirGuard {
    pub path: PathBuf,
}

impl TempDirGuard {
    pub fn new(prefix: &str) -> Self {
        let seq = COMMON_SEQ.fetch_add(1, Ordering::Relaxed);
        let dir =
            std::env::temp_dir().join(format!("b3-test-{prefix}-{}-{seq}", std::process::id()));
        if dir.exists() {
            let _ = b3::fs::remove_dir_tree_safely(&dir);
        }
        fs::create_dir_all(&dir).expect("create temp dir");
        Self { path: dir }
    }
}

impl Drop for TempDirGuard {
    fn drop(&mut self) {
        let _ = b3::fs::remove_dir_tree_safely(&self.path);
    }
}

pub fn remove_tree_safe(path: &Path) {
    let _ = b3::fs::remove_dir_tree_safely(path);
}

pub fn norm_lf(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes)
        .replace("\r\n", "\n")
        .trim_end_matches('\n')
        .to_string()
}

pub fn run_b3(args: &[&str]) -> (i32, String, String) {
    run_b3_env(args, None, &[], &[])
}

pub fn run_b3_with_env(args: &[&str], envs: &[(&str, &str)]) -> (i32, String, String) {
    run_b3_env(args, None, envs, &[])
}

pub fn run_b3_env(
    args: &[&str],
    cwd: Option<&Path>,
    envs: &[(&str, &str)],
    unset: &[&str],
) -> (i32, String, String) {
    let mut cmd = Command::new(b3_bin());
    cmd.args(args);
    if let Some(dir) = cwd {
        cmd.current_dir(dir);
    }
    for k in unset {
        cmd.env_remove(k);
    }
    for (k, v) in envs {
        cmd.env(k, v);
    }
    let out = cmd.output().expect("execute b3 binary");
    (
        out.status.code().unwrap_or(-1),
        norm_lf(&out.stdout),
        norm_lf(&out.stderr),
    )
}

pub fn git_in_status(dir: &Path, args: &[&str]) -> (i32, String, String) {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .expect("execute git");
    (
        out.status.code().unwrap_or(-1),
        norm_lf(&out.stdout),
        norm_lf(&out.stderr),
    )
}

pub fn git_in(dir: &Path, args: &[&str]) -> String {
    let (code, stdout, stderr) = git_in_status(dir, args);
    assert_eq!(code, 0, "git {:?} failed: {stderr}", args);
    stdout.trim().to_string()
}

pub fn write_lf(path: &Path, content: &str) {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("create parent dirs");
    }
    fs::write(path, content.replace("\r\n", "\n").as_bytes()).expect("write LF file");
}

pub fn copy_dir_recursive(src: &Path, dst: &Path) {
    fs::create_dir_all(dst).expect("create copy dst");
    for entry in fs::read_dir(src).expect("read src dir") {
        let entry = entry.expect("dir entry");
        let name = entry.file_name();
        let src_p = entry.path();
        let dst_p = dst.join(name);
        let meta = fs::symlink_metadata(&src_p).expect("symlink_metadata");
        if meta.file_type().is_symlink() || b3::fs::is_reparse_or_symlink(&src_p) {
            continue;
        }
        if meta.is_dir() {
            copy_dir_recursive(&src_p, &dst_p);
        } else {
            fs::copy(&src_p, &dst_p).expect("copy file");
        }
    }
}

pub fn init_fresh_git_repo(dir: &Path) -> String {
    fs::create_dir_all(dir).expect("create repo dir");
    let out = Command::new("git")
        .arg("init")
        .arg(dir)
        .output()
        .expect("git init");
    assert!(out.status.success(), "git init failed");
    git_in(dir, &["symbolic-ref", "HEAD", "refs/heads/main"]);
    git_in(dir, &["config", "user.email", "test@b3.local"]);
    git_in(dir, &["config", "user.name", "B3 Tester"]);
    git_in(dir, &["config", "core.autocrlf", "false"]);
    write_lf(&dir.join("src/app.txt"), "v1\n");
    write_lf(&dir.join("docs/guide.md"), "doc v1\n");
    git_in(dir, &["add", "."]);
    git_in(dir, &["commit", "-m", "initial"]);
    git_in(dir, &["rev-parse", "HEAD"])
}

pub fn clone_seeded_git_repo(dest: &Path) -> String {
    let (seed_dir, seed_sha) = SEED_REPO.get_or_init(|| {
        let dir = std::env::temp_dir().join(format!("b3-seed-repo-{}", std::process::id()));
        if dir.exists() {
            let _ = b3::fs::remove_dir_tree_safely(&dir);
        }
        let sha = init_fresh_git_repo(&dir);
        (dir, sha)
    });
    if dest.exists() {
        let _ = b3::fs::remove_dir_tree_safely(dest);
    }
    copy_dir_recursive(seed_dir, dest);
    seed_sha.clone()
}

pub fn init_git_repo(dir: &Path) -> String {
    clone_seeded_git_repo(dir)
}

pub fn create_dir_link(link: &Path, target: &Path) {
    if let Some(parent) = link.parent() {
        fs::create_dir_all(parent).expect("create link parent");
    }
    b3::adapters::common::create_dir_link(link, target).expect("create_dir_link");
}

pub fn write_mock_gh(dir: &Path, stem: &str, js_body: &str) -> PathBuf {
    fs::create_dir_all(dir).expect("create mock gh dir");
    let js_path = dir.join(format!("{stem}.js"));
    write_lf(&js_path, js_body);
    if cfg!(windows) {
        let cmd_path = dir.join(format!("{stem}.cmd"));
        let cmd_body = format!("@echo off\r\nnode \"%~dp0{stem}.js\" %*\r\n");
        fs::write(&cmd_path, cmd_body.as_bytes()).expect("write mock gh cmd");
        cmd_path
    } else {
        let sh_path = dir.join(stem);
        let sh_body = format!("#!/bin/sh\nexec node \"$(dirname \"$0\")/{stem}.js\" \"$@\"\n");
        write_lf(&sh_path, &sh_body);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = fs::metadata(&sh_path).unwrap().permissions();
            perms.set_mode(0o755);
            fs::set_permissions(&sh_path, perms).unwrap();
        }
        sh_path
    }
}

pub fn replace_path_variants(mut s: String, raw: &Path, token: &str) -> String {
    let mut candidates = vec![raw.to_string_lossy().into_owned()];
    let long = b3::fs::expand_windows_long_path(raw);
    let long_str = long.to_string_lossy().into_owned();
    if !candidates.contains(&long_str) {
        candidates.push(long_str);
    }
    if let Ok(canon) = fs::canonicalize(raw) {
        let cs = canon.to_string_lossy().into_owned();
        let trimmed = cs.strip_prefix("\\\\?\\").unwrap_or(&cs).to_string();
        if !candidates.contains(&trimmed) {
            candidates.push(trimmed);
        }
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
