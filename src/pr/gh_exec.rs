use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crate::fs::has_control_chars;
use crate::process::run_command_timeout;

fn is_valid_slug_char(b: u8) -> bool {
    b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-')
}

/// Validates `<owner>/<repo>` slug syntax without traversal or control characters.
pub fn validate_repo_slug(repo_raw: &str) -> Result<(String, String, String), &'static str> {
    let repo = repo_raw.trim();
    if repo.is_empty() || has_control_chars(repo) || repo.contains("..") {
        return Err("invalid_repo");
    }
    let Some((owner, name)) = repo.split_once('/') else {
        return Err("invalid_repo");
    };
    if name.contains('/')
        || owner.is_empty()
        || name.is_empty()
        || !owner.bytes().all(is_valid_slug_char)
        || !name.bytes().all(is_valid_slug_char)
    {
        return Err("invalid_repo");
    }
    if owner == "." || name == "." {
        return Err("invalid_repo_segments");
    }
    Ok((
        owner.to_string(),
        name.to_string(),
        format!("{owner}/{name}"),
    ))
}

/// Validates a strictly positive base-10 PR number string.
pub fn validate_pr_number(pr_raw: &str) -> Result<(u64, String), &'static str> {
    let pr_str = pr_raw.trim();
    if pr_str.is_empty()
        || has_control_chars(pr_str)
        || pr_str.starts_with('0')
        || !pr_str.bytes().all(|b| b.is_ascii_digit())
    {
        return Err("invalid_pr_number");
    }
    let Ok(num) = pr_str.parse::<u64>() else {
        return Err("invalid_pr_number");
    };
    if num == 0 {
        return Err("invalid_pr_number");
    }
    Ok((num, pr_str.to_string()))
}

/// Extracts `owner/repo` from HTTPS or SSH GitHub remote URLs.
pub fn parse_github_remote_slug(remote_url: &str) -> Option<String> {
    let mut u = remote_url.trim();
    if u.is_empty() {
        return None;
    }
    while let Some(stripped) = u.strip_suffix('/') {
        u = stripped;
    }
    if u.len() >= 4 && u[u.len() - 4..].eq_ignore_ascii_case(".git") {
        u = &u[..u.len() - 4];
    }

    let u_low = u.to_ascii_lowercase();
    let slug = if u_low.starts_with("https://") {
        let rest = &u["https://".len()..];
        let host_and_path = match rest.find('/') {
            Some(slash) => {
                let auth_host = &rest[..slash];
                let host = match auth_host.rsplit_once('@') {
                    Some((_, h)) => h,
                    None => auth_host,
                };
                if !host.eq_ignore_ascii_case("github.com") {
                    return None;
                }
                &rest[slash + 1..]
            }
            None => return None,
        };
        host_and_path
    } else if let Some(rest) = u
        .strip_prefix("ssh://git@")
        .or_else(|| u.strip_prefix("SSH://git@"))
        .or_else(|| u.strip_prefix("git@"))
        .or_else(|| {
            if u_low.starts_with("ssh://") && u_low[6..].starts_with("git@") {
                Some(&u[10..])
            } else {
                None
            }
        })
    {
        if rest.len() < 11 {
            return None;
        }
        if !rest[..10].eq_ignore_ascii_case("github.com") {
            return None;
        }
        let sep = rest.as_bytes()[10];
        if sep != b':' && sep != b'/' {
            return None;
        }
        &rest[11..]
    } else {
        return None;
    };

    if slug.contains("..") {
        return None;
    }
    let (owner, name) = slug.split_once('/')?;
    if name.contains('/')
        || owner.is_empty()
        || name.is_empty()
        || !owner.bytes().all(is_valid_slug_char)
        || !name.bytes().all(is_valid_slug_char)
    {
        return None;
    }
    Some(format!("{owner}/{name}"))
}

pub fn is_windows_apps_stub(file_path: &Path) -> bool {
    if !cfg!(windows) {
        return false;
    }
    let norm = file_path
        .to_string_lossy()
        .replace('/', "\\")
        .to_ascii_lowercase();
    norm.contains("\\microsoft\\windowsapps\\")
}

pub fn is_executable_or_file(file_path: &Path) -> bool {
    let raw = file_path.to_string_lossy();
    if raw.is_empty() || has_control_chars(&raw) || is_windows_apps_stub(file_path) {
        return false;
    }
    let Ok(meta) = std::fs::metadata(file_path) else {
        return false;
    };
    if !meta.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        (meta.permissions().mode() & 0o111) != 0
    }
    #[cfg(not(unix))]
    {
        true
    }
}

fn try_file_or_win_exts(candidate: &str) -> Option<PathBuf> {
    if candidate.is_empty() || has_control_chars(candidate) {
        return None;
    }
    let p = PathBuf::from(candidate);
    if is_executable_or_file(&p) {
        return Some(p);
    }
    if cfg!(windows) {
        let leaf = p.file_name().and_then(|n| n.to_str()).unwrap_or("");
        let has_ext = leaf.rsplit_once('.').is_some_and(|(_, ext)| {
            !ext.is_empty() && ext.bytes().all(|b| b.is_ascii_alphanumeric())
        });
        if !has_ext {
            for ext in [".exe", ".com", ".cmd", ".bat"] {
                let p_ext = PathBuf::from(format!("{candidate}{ext}"));
                if is_executable_or_file(&p_ext) {
                    return Some(p_ext);
                }
            }
        }
    }
    None
}

fn find_first_in_path(dirs: &[PathBuf], names: &[&str]) -> Option<PathBuf> {
    for d in dirs {
        for n in names {
            let full = d.join(n);
            if is_executable_or_file(&full) {
                return Some(full);
            }
        }
    }
    None
}

fn path_dirs_from_env() -> Vec<PathBuf> {
    let path_os = std::env::var_os("PATH")
        .or_else(|| std::env::var_os("Path"))
        .unwrap_or_default();
    std::env::split_paths(&path_os)
        .filter(|p| !p.as_os_str().is_empty())
        .collect()
}

pub fn resolve_bash_binary(explicit_bash: &str) -> Option<PathBuf> {
    let env_bash = std::env::var("B3_BASH_BIN").unwrap_or_default();
    let raw = if !explicit_bash.trim().is_empty() {
        explicit_bash.trim()
    } else {
        env_bash.trim()
    };

    if !raw.is_empty() {
        if has_control_chars(raw) {
            return None;
        }
        if let Some(hit) = try_file_or_win_exts(raw) {
            return Some(hit);
        }
        if cfg!(windows) && raw.starts_with('/') && !raw.starts_with("//") {
            let bytes = raw.as_bytes();
            if bytes.len() >= 3 && bytes[1].is_ascii_alphabetic() && bytes[2] == b'/' {
                let drive = bytes[1] as char;
                let rest = raw[3..].replace('/', "\\");
                if let Some(hit) = try_file_or_win_exts(&format!("{drive}:\\{rest}")) {
                    return Some(hit);
                }
            }
        }
        return None;
    }

    if cfg!(windows) {
        let mut cands = Vec::new();
        if let Ok(pf) = std::env::var("ProgramFiles") {
            let pf_p = PathBuf::from(pf);
            cands.push(pf_p.join("Git\\bin\\bash.exe"));
            cands.push(pf_p.join("Git\\usr\\bin\\bash.exe"));
        }
        cands.push(PathBuf::from("C:\\Program Files\\Git\\bin\\bash.exe"));
        cands.push(PathBuf::from("C:\\Program Files\\Git\\usr\\bin\\bash.exe"));
        cands.push(PathBuf::from("C:\\Program Files (x86)\\Git\\bin\\bash.exe"));
        for cand in cands {
            if is_executable_or_file(&cand) {
                return Some(cand);
            }
        }
    }

    let dirs = path_dirs_from_env();
    for d in dirs {
        let full = d.join(if cfg!(windows) { "bash.exe" } else { "bash" });
        if cfg!(windows) {
            let low = full
                .to_string_lossy()
                .replace('/', "\\")
                .to_ascii_lowercase();
            if low.ends_with("\\windows\\system32\\bash.exe")
                || low.ends_with("\\windows\\sysnative\\bash.exe")
                || low.ends_with("\\microsoft\\windowsapps\\bash.exe")
            {
                continue;
            }
        }
        if is_executable_or_file(&full) {
            return Some(full);
        }
    }
    None
}

fn resolve_win_msys_candidate(candidate_raw: &str) -> Option<PathBuf> {
    let bytes = candidate_raw.as_bytes();
    if bytes.len() >= 3 && bytes[0] == b'/' && bytes[1].is_ascii_alphabetic() && bytes[2] == b'/' {
        let drive = bytes[1] as char;
        let rest = candidate_raw[3..].replace('/', "\\");
        if let Some(hit) = try_file_or_win_exts(&format!("{drive}:\\{rest}")) {
            return Some(hit);
        }
    }
    let bash_bin = resolve_bash_binary("")?;
    let bash_dir = bash_bin.parent()?;
    let cyg_cands = [
        bash_dir.join("cygpath.exe"),
        bash_dir.join("..\\usr\\bin\\cygpath.exe"),
    ];
    let no_env: [(&str, &str); 0] = [];
    for cyg in cyg_cands {
        if is_executable_or_file(&cyg) {
            if let Ok(r) = run_command_timeout(
                cyg.as_os_str(),
                &["-w", "--", candidate_raw],
                None,
                &no_env,
                &[],
                None,
                Some(5000),
            ) {
                if r.exit_code == 0 {
                    let s = String::from_utf8_lossy(&r.stdout).trim().to_string();
                    if !s.is_empty() {
                        return try_file_or_win_exts(&s);
                    }
                }
            }
            break;
        }
    }
    if let Ok(r) = run_command_timeout(
        bash_bin.as_os_str(),
        &["-c", "cygpath -w -- \"$1\"", "_", candidate_raw],
        None,
        &no_env,
        &[],
        None,
        Some(5000),
    ) {
        if r.exit_code == 0 {
            let s = String::from_utf8_lossy(&r.stdout).trim().to_string();
            if !s.is_empty() {
                return try_file_or_win_exts(&s);
            }
        }
    }
    None
}

/// Resolves `gh` CLI binary via explicit path, `B3_GH_BIN`, MSYS translation, or `PATH`.
pub fn resolve_gh_binary(explicit_gh: &str) -> Option<PathBuf> {
    let env_gh = std::env::var("B3_GH_BIN").unwrap_or_default();
    let cand = if !explicit_gh.trim().is_empty() {
        explicit_gh.trim()
    } else {
        env_gh.trim()
    };
    if has_control_chars(cand) {
        return None;
    }
    let dirs = path_dirs_from_env();
    if !cand.is_empty() {
        let has_sep = cand.contains('/')
            || cand.contains('\\')
            || (cfg!(windows)
                && cand.len() >= 2
                && cand.as_bytes()[0].is_ascii_alphabetic()
                && cand.as_bytes()[1] == b':');
        if has_sep {
            if let Some(hit) = try_file_or_win_exts(cand) {
                return Some(hit);
            }
            if cfg!(windows) && cand.starts_with('/') && !cand.starts_with("//") {
                if let Some(msys) = resolve_win_msys_candidate(cand) {
                    return Some(msys);
                }
            }
            return None;
        }
        let leaf_has_ext = cand.rsplit_once('.').is_some_and(|(_, ext)| {
            !ext.is_empty() && ext.bytes().all(|b| b.is_ascii_alphanumeric())
        });
        if cfg!(windows) && !leaf_has_ext {
            let names = [
                format!("{cand}.exe"),
                format!("{cand}.com"),
                format!("{cand}.cmd"),
                format!("{cand}.bat"),
                cand.to_string(),
            ];
            let refs: Vec<&str> = names.iter().map(String::as_str).collect();
            return find_first_in_path(&dirs, &refs);
        }
        return find_first_in_path(&dirs, &[cand]);
    }
    let names: &[&str] = if cfg!(windows) {
        &["gh.exe", "gh.com", "gh.cmd", "gh.bat", "gh"]
    } else {
        &["gh"]
    };
    find_first_in_path(&dirs, names)
}

#[derive(Debug, Clone)]
pub struct GhExecResult {
    pub ok: bool,
    pub reason: &'static str,
    pub status: Option<i32>,
    pub stdout: String,
    pub stderr: String,
}

fn fail_gh_exec(reason: &'static str) -> GhExecResult {
    GhExecResult {
        ok: false,
        reason,
        status: None,
        stdout: String::new(),
        stderr: String::new(),
    }
}

/// Executes `gh_bin` safely without shell interpolation or MSYS POSIX path mangling.
pub fn exec_gh(
    args: &[String],
    gh_bin: &Path,
    bash_bin: Option<&Path>,
    stdin_bytes: Option<&[u8]>,
    timeout_ms: Option<u64>,
) -> GhExecResult {
    let gh_str = gh_bin.to_string_lossy();
    if gh_str.is_empty() || has_control_chars(&gh_str) || gh_str.contains('"') {
        return fail_gh_exec("unsafe_gh_path");
    }
    for a in args {
        if has_control_chars(a) {
            return fail_gh_exec("unsafe_gh_arg");
        }
    }
    let timeout_val = timeout_ms.unwrap_or(60_000);
    let timeout = Some(timeout_val);
    let ext_low = gh_bin
        .extension()
        .and_then(|e| e.to_str())
        .map(|s| s.to_ascii_lowercase())
        .unwrap_or_default();

    #[cfg(windows)]
    if ext_low == "cmd" || ext_low == "bat" {
        if gh_str.bytes().any(|b| {
            matches!(
                b,
                b'!' | b'"' | b'&' | b'|' | b'<' | b'>' | b'^' | b'%' | b'(' | b')'
            )
        }) {
            return fail_gh_exec("unsafe_gh_path");
        }
        for a in args {
            if a.contains('"') || a.ends_with('\\') {
                return fail_gh_exec("unsafe_gh_arg");
            }
        }
        let comspec = std::env::var("ComSpec")
            .or_else(|_| std::env::var("COMSPEC"))
            .unwrap_or_else(|_| "cmd.exe".to_string());
        if has_control_chars(&comspec)
            || comspec
                .bytes()
                .any(|b| matches!(b, b'"' | b'&' | b'|' | b'<' | b'>' | b'^' | b'%' | b'!'))
        {
            return fail_gh_exec("unsafe_comspec");
        }
        return exec_win_batch_cmd(&comspec, &gh_str, args, stdin_bytes, timeout_val);
    }

    #[cfg(windows)]
    if ext_low != "exe" && ext_low != "com" {
        let Some(bash) = bash_bin else {
            return fail_gh_exec("bash_not_found");
        };
        let bash_str = bash.to_string_lossy();
        if has_control_chars(&bash_str) {
            return fail_gh_exec("bash_not_found");
        }
        let mut b_args = Vec::with_capacity(2 + args.len());
        b_args.push("--".to_string());
        b_args.push(gh_str.replace('\\', "/"));
        b_args.extend(args.iter().cloned());
        let env_gh = [("GH_PROMPT_DISABLED", "1")];
        return match run_command_timeout(
            bash.as_os_str(),
            &b_args,
            None,
            &env_gh,
            &[],
            stdin_bytes,
            timeout,
        ) {
            Ok(out) if out.exit_code == 124 => fail_gh_exec("timeout"),
            Ok(out) => GhExecResult {
                ok: true,
                reason: "",
                status: Some(out.exit_code),
                stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
                stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
            },
            Err(_) => fail_gh_exec("spawn_error"),
        };
    }

    #[cfg(not(windows))]
    let _ = (bash_bin, ext_low);

    let env_gh = [("GH_PROMPT_DISABLED", "1")];
    match run_command_timeout(
        gh_bin.as_os_str(),
        args,
        None,
        &env_gh,
        &[],
        stdin_bytes,
        timeout,
    ) {
        Ok(out) if out.exit_code == 124 => fail_gh_exec("timeout"),
        Ok(out) => GhExecResult {
            ok: true,
            reason: "",
            status: Some(out.exit_code),
            stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
        },
        Err(_) => fail_gh_exec("spawn_error"),
    }
}

#[cfg(windows)]
fn exec_win_batch_cmd(
    comspec: &str,
    gh_bin: &str,
    args: &[String],
    stdin_bytes: Option<&[u8]>,
    timeout_ms: u64,
) -> GhExecResult {
    use std::io::{Read, Write};
    use std::os::windows::process::CommandExt;
    use std::process::{Command, Stdio};

    let mut cmd = Command::new(comspec);
    cmd.env("GH_PROMPT_DISABLED", "1");
    cmd.env("B3_GH_CMD_EXE", gh_bin);

    let mut tokens = Vec::with_capacity(args.len() + 1);
    tokens.push("\"%B3_GH_CMD_EXE%\"".to_string());
    for (idx, a) in args.iter().enumerate() {
        if a.is_empty() {
            tokens.push("\"\"".to_string());
        } else {
            let k = format!("B3_GH_CMD_{idx}");
            cmd.env(&k, a);
            tokens.push(format!("\"%{k}%\""));
        }
    }
    let cmd_line = format!("\"{}\"", tokens.join(" "));
    cmd.raw_arg("/d")
        .raw_arg("/v:off")
        .raw_arg("/s")
        .raw_arg("/c")
        .raw_arg(&cmd_line);
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    cmd.creation_flags(CREATE_NO_WINDOW);
    if stdin_bytes.is_some() {
        cmd.stdin(Stdio::piped());
    } else {
        cmd.stdin(Stdio::null());
    }
    cmd.stdout(Stdio::piped());
    cmd.stderr(Stdio::piped());

    let Ok(mut child) = cmd.spawn() else {
        return fail_gh_exec("spawn_error");
    };
    let mut child_stdin = child.stdin.take();
    let Some(mut child_stdout) = child.stdout.take() else {
        let _ = child.kill();
        return fail_gh_exec("spawn_error");
    };
    let Some(mut child_stderr) = child.stderr.take() else {
        let _ = child.kill();
        return fail_gh_exec("spawn_error");
    };

    std::thread::scope(|scope| {
        let sin_h = stdin_bytes.map(|bytes| {
            scope.spawn(move || {
                if let Some(mut s) = child_stdin.take() {
                    if !bytes.is_empty() {
                        let _ = s.write_all(bytes);
                    }
                    let _ = s.flush();
                }
            })
        });
        let sout_h = scope.spawn(move || {
            let mut buf = Vec::new();
            let _ = child_stdout.read_to_end(&mut buf);
            buf
        });
        let serr_h = scope.spawn(move || {
            let mut buf = Vec::new();
            let _ = child_stderr.read_to_end(&mut buf);
            buf
        });

        let deadline = Instant::now() + Duration::from_millis(timeout_ms);
        let status_code = loop {
            match child.try_wait() {
                Ok(Some(st)) => break Some(st.code().unwrap_or(1)),
                Ok(None) => {
                    if Instant::now() >= deadline {
                        let _ = child.kill();
                        let _ = child.wait();
                        break None;
                    }
                    std::thread::sleep(Duration::from_millis(20));
                }
                Err(_) => break Some(1),
            }
        };
        if let Some(h) = sin_h {
            let _ = h.join();
        }
        let stdout_bytes = sout_h.join().unwrap_or_default();
        let stderr_bytes = serr_h.join().unwrap_or_default();
        match status_code {
            None => fail_gh_exec("timeout"),
            Some(code) => GhExecResult {
                ok: true,
                reason: "",
                status: Some(code),
                stdout: String::from_utf8_lossy(&stdout_bytes).into_owned(),
                stderr: String::from_utf8_lossy(&stderr_bytes).into_owned(),
            },
        }
    })
}
