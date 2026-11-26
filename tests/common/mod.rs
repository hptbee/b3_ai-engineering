#![allow(dead_code)]
//! Shared test fixtures and helpers for B3 integration tests.
//! Uses a process-wide cached seed git repository to eliminate repeated `git init` / `config` / `commit` spawns.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::OnceLock;

static TEST_SEQ: AtomicU64 = AtomicU64::new(0);
static GIT_SEED: OnceLock<(PathBuf, String)> = OnceLock::new();

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
        let seq = TEST_SEQ.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!(
            "b3-rust-test-{prefix}-{}-{seq}",
            std::process::id()
        ));
        if dir.exists() {
            remove_tree_safe(&dir);
        }
        fs::create_dir_all(&dir).expect("create temp dir");
        Self { path: dir }
    }
}

impl Drop for TempDirGuard {
    fn drop(&mut self) {
        remove_tree_safe(&self.path);
    }
}

pub fn remove_tree_safe(path: &Path) {
    #[cfg(windows)]
    {
        let _ = Command::new("cmd")
            .args([
                "/d",
                "/c",
                &format!(
                    "for /d %d in (\"{}\") do @rmdir /s /q \"%d\" 2>nul",
                    path.display()
                ),
            ])
            .status();
    }
    let _ = fs::remove_dir_all(path);
}

pub fn norm_lf(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes)
        .replace("\r\n", "\n")
        .trim_end_matches('\n')
        .to_string()
}

pub fn git_in(dir: &Path, args: &[&str]) -> String {
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

pub fn copy_dir_recursive(src: &Path, dst: &Path) {
    fs::create_dir_all(dst).expect("create dst dir");
    for entry in fs::read_dir(src).expect("read_dir") {
        let entry = entry.expect("dir entry");
        let ty = entry.file_type().expect("file_type");
        let dst_path = dst.join(entry.file_name());
        if ty.is_dir() {
            copy_dir_recursive(&entry.path(), &dst_path);
        } else if ty.is_file() {
            fs::copy(entry.path(), &dst_path).expect("copy file");
        }
    }
}

fn get_or_init_seed_repo() -> &'static (PathBuf, String) {
    GIT_SEED.get_or_init(|| {
        let seed_dir = std::env::temp_dir().join(format!("b3-git-seed-{}", std::process::id()));
        if seed_dir.exists() {
            let _ = fs::remove_dir_all(&seed_dir);
        }
        fs::create_dir_all(&seed_dir).expect("create seed dir");
        let out = Command::new("git")
            .arg("init")
            .arg(&seed_dir)
            .output()
            .expect("git init seed");
        assert!(out.status.success(), "git init seed failed");
        git_in(&seed_dir, &["symbolic-ref", "HEAD", "refs/heads/main"]);
        git_in(&seed_dir, &["config", "user.email", "test@example.com"]);
        git_in(&seed_dir, &["config", "user.name", "B3 Tester"]);
        git_in(&seed_dir, &["config", "core.autocrlf", "false"]);
        fs::create_dir_all(seed_dir.join("src")).unwrap();
        fs::create_dir_all(seed_dir.join("docs")).unwrap();
        fs::write(seed_dir.join("src/app.txt"), "v1\n").unwrap();
        fs::write(seed_dir.join("docs/guide.md"), "doc v1\n").unwrap();
        git_in(&seed_dir, &["add", "."]);
        git_in(&seed_dir, &["commit", "-m", "initial"]);
        let head = git_in(&seed_dir, &["rev-parse", "HEAD"]);
        (seed_dir, head)
    })
}

/// Initializes a clean git repository at `dir` by cloning the cached seed template in-process.
/// Returns the initial commit SHA (`HEAD`). Spawns zero `git` subprocesses after first call.
pub fn init_git_repo(dir: &Path) -> String {
    let (seed_dir, head) = get_or_init_seed_repo();
    copy_dir_recursive(seed_dir, dir);
    head.clone()
}

pub fn run_b3(args: &[&str]) -> (i32, String, String) {
    run_b3_with_env(args, &[])
}

pub fn run_b3_with_env(args: &[&str], envs: &[(&str, &str)]) -> (i32, String, String) {
    let mut cmd = Command::new(b3_bin());
    cmd.args(args);
    for (k, v) in envs {
        cmd.env(k, v);
    }
    let out: Output = cmd.output().expect("run b3 binary");
    (
        out.status.code().unwrap_or(-1),
        norm_lf(&out.stdout),
        norm_lf(&out.stderr),
    )
}
