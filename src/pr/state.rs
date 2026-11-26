use std::collections::HashSet;
use std::ffi::OsStr;
use std::fs::{self, OpenOptions};
use std::io::{ErrorKind, Write};
use std::path::{Path, PathBuf};

use crate::fs::{
    has_control_chars, is_reparse_or_symlink, next_tmp_suffix, paths_equal_fs,
    resolve_unresolved_path, sha256_bytes_hex,
};
use crate::guard::verify::format_utc_iso8601_now;
use crate::json::{parse_json, JsonValue};
use crate::process::{probe_pid_liveness, PidLiveness};

pub const EXIT_OK: i32 = 0;
pub const EXIT_ERROR: i32 = 1;
pub const EXIT_BLOCKED: i32 = 2;

pub const MAX_FILE_BYTES: u64 = 262_144;

/// Non-panicking structured JSON exit for `b3 pr` GitHub adapter subcommands.
#[derive(Debug, Clone)]
pub struct PrExit {
    pub payload: JsonValue,
    pub code: i32,
}

pub fn pr_emit(payload: JsonValue, code: i32) -> PrExit {
    PrExit { payload, code }
}

pub fn pr_fail(
    status: &str,
    message: impl Into<String>,
    code: i32,
    extra: Vec<(String, JsonValue)>,
) -> PrExit {
    let mut entries = Vec::with_capacity(2 + extra.len());
    entries.push(("status".to_string(), JsonValue::str(status)));
    entries.push(("error".to_string(), JsonValue::str(message)));
    entries.extend(extra);
    PrExit {
        payload: JsonValue::Object(entries),
        code,
    }
}

pub fn is_win_reserved_device_name(name: &str) -> bool {
    let bytes = name.as_bytes();
    let len = bytes.len();
    let check_stem = |s: &str| -> bool {
        let up = s.to_ascii_uppercase();
        matches!(up.as_str(), "CON" | "PRN" | "AUX" | "NUL")
            || (up.len() == 4
                && (up.starts_with("COM") || up.starts_with("LPT"))
                && matches!(up.as_bytes()[3], b'1'..=b'9'))
    };
    if let Some(dot) = name.find('.') {
        let stem = &name[..dot];
        let _ = (bytes, len);
        check_stem(stem)
    } else {
        check_stem(name)
    }
}

/// Validates raw path syntax against control chars, UNC/device prefixes, traversal, and Windows device names.
pub fn validate_raw_path_syntax(
    file_path: &str,
    flag_name: &str,
    reject_traversal: bool,
) -> Result<(), PrExit> {
    if file_path.is_empty() || has_control_chars(file_path) || file_path.contains('\0') {
        return Err(pr_fail(
            "PR_INVALID_ARGS",
            format!("Invalid {flag_name}"),
            EXIT_ERROR,
            Vec::new(),
        ));
    }
    if file_path.starts_with("\\\\")
        || file_path.starts_with("//")
        || file_path.starts_with("\\/")
        || file_path.starts_with("/\\")
    {
        return Err(pr_fail(
            "PR_FILE_GUARD",
            format!("UNC/device namespace path rejected for {flag_name}"),
            EXIT_ERROR,
            Vec::new(),
        ));
    }
    let fb = file_path.as_bytes();
    if fb.len() >= 2
        && fb[0].is_ascii_alphabetic()
        && fb[1] == b':'
        && (fb.len() == 2 || (fb[2] != b'\\' && fb[2] != b'/'))
    {
        return Err(pr_fail(
            "PR_FILE_GUARD",
            format!("Drive-relative path rejected for {flag_name}"),
            EXIT_ERROR,
            Vec::new(),
        ));
    }
    let without_drive = if fb.len() >= 2 && fb[0].is_ascii_alphabetic() && fb[1] == b':' {
        &file_path[2..]
    } else {
        file_path
    };
    if without_drive.contains(':') {
        return Err(pr_fail(
            "PR_FILE_GUARD",
            format!("Unsafe path syntax rejected for {flag_name}"),
            EXIT_ERROR,
            Vec::new(),
        ));
    }
    for seg in without_drive.split(['\\', '/']).filter(|s| !s.is_empty()) {
        if reject_traversal && seg == ".." {
            return Err(pr_fail(
                "PR_FILE_GUARD",
                format!("Path traversal rejected for {flag_name}"),
                EXIT_ERROR,
                Vec::new(),
            ));
        }
        let cleaned = seg
            .trim_end_matches(|c: char| c.is_whitespace() || c == '.')
            .trim();
        let base_stem = seg.split('.').next().unwrap_or("").trim();
        if is_win_reserved_device_name(cleaned) || is_win_reserved_device_name(base_stem) {
            return Err(pr_fail(
                "PR_FILE_GUARD",
                format!("Reserved device path rejected for {flag_name}"),
                EXIT_ERROR,
                Vec::new(),
            ));
        }
    }
    Ok(())
}

/// Ensures every existing ancestor directory of `target_path` is a real directory (not a symlink/junction).
pub fn assert_ancestors_safe(target_path: &Path, flag_name: &str) -> Result<(), PrExit> {
    let mut visited = HashSet::new();
    let mut cur_opt = target_path.parent().map(Path::to_path_buf);
    while let Some(cur) = cur_opt {
        if cur.as_os_str().is_empty() || !visited.insert(cur.clone()) {
            break;
        }
        #[cfg(target_os = "macos")]
        {
            if cur == Path::new("/var") || cur == Path::new("/tmp") || cur == Path::new("/etc") {
                break;
            }
        }
        match fs::symlink_metadata(&cur) {
            Ok(pst) => {
                if pst.file_type().is_symlink() || is_reparse_or_symlink(&cur) {
                    return Err(pr_fail(
                        "PR_FILE_GUARD",
                        format!("Symlink/reparse ancestor directory rejected for {flag_name}"),
                        EXIT_ERROR,
                        Vec::new(),
                    ));
                }
                if !pst.is_dir() {
                    return Err(pr_fail(
                        "PR_FILE_GUARD",
                        format!("Non-directory ancestor rejected for {flag_name}"),
                        EXIT_ERROR,
                        Vec::new(),
                    ));
                }
            }
            Err(e) if e.kind() == ErrorKind::NotFound => {}
            Err(e) => {
                return Err(pr_fail(
                    "PR_FILE_GUARD",
                    format!(
                        "Cannot inspect ancestor for {flag_name}: {}",
                        e.raw_os_error().unwrap_or(1)
                    ),
                    EXIT_ERROR,
                    Vec::new(),
                ));
            }
        }
        cur_opt = cur.parent().map(Path::to_path_buf);
    }
    Ok(())
}

/// Lexically resolves `target_path`, rejects symlinks/reparse points and oversized files, and checks ancestors.
pub fn validate_safe_path(
    target_path: &str,
    flag_name: &str,
    expect_dir: bool,
    must_exist: bool,
    max_bytes: u64,
) -> Result<PathBuf, PrExit> {
    validate_raw_path_syntax(target_path, flag_name, true)?;
    let cwd = std::env::current_dir().map_err(|e| {
        pr_fail(
            "PR_FILE_GUARD",
            format!("Cannot resolve current directory for {flag_name}: {e}"),
            EXIT_ERROR,
            Vec::new(),
        )
    })?;
    let resolved = resolve_unresolved_path(&cwd, target_path);
    match fs::symlink_metadata(&resolved) {
        Ok(st) => {
            if st.file_type().is_symlink() || is_reparse_or_symlink(&resolved) {
                return Err(pr_fail(
                    "PR_FILE_GUARD",
                    format!("Symlink/reparse point rejected for {flag_name}"),
                    EXIT_ERROR,
                    Vec::new(),
                ));
            }
            if expect_dir {
                if !st.is_dir() {
                    return Err(pr_fail(
                        "PR_FILE_GUARD",
                        format!("Directory required for {flag_name}"),
                        EXIT_ERROR,
                        Vec::new(),
                    ));
                }
            } else {
                if !st.is_file() {
                    return Err(pr_fail(
                        "PR_FILE_GUARD",
                        format!("Regular file required for {flag_name}"),
                        EXIT_ERROR,
                        Vec::new(),
                    ));
                }
                if must_exist && st.len() > max_bytes {
                    return Err(pr_fail(
                        "PR_FILE_GUARD",
                        format!("{flag_name} exceeds {max_bytes} bytes"),
                        EXIT_ERROR,
                        Vec::new(),
                    ));
                }
            }
        }
        Err(e) if !must_exist && e.kind() == ErrorKind::NotFound => {}
        Err(e) => {
            return Err(pr_fail(
                "PR_FILE_GUARD",
                format!(
                    "Cannot access {flag_name}: {}",
                    e.raw_os_error().unwrap_or(1)
                ),
                EXIT_ERROR,
                Vec::new(),
            ));
        }
    }
    assert_ancestors_safe(&resolved, flag_name)?;
    Ok(resolved)
}

/// Safely reads an input UTF-8 file (stripping optional leading BOM) up to `max_bytes`.
pub fn read_safe_input_file(
    file_path: &str,
    flag_name: &str,
    max_bytes: u64,
) -> Result<String, PrExit> {
    let resolved = validate_safe_path(file_path, flag_name, false, true, max_bytes)?;
    let raw = fs::read_to_string(&resolved).map_err(|e| {
        pr_fail(
            "PR_FILE_GUARD",
            format!("Cannot read {flag_name}: {e}"),
            EXIT_ERROR,
            Vec::new(),
        )
    })?;
    Ok(raw.strip_prefix('\u{FEFF}').unwrap_or(&raw).to_string())
}

pub fn same_fs_path(a: &Path, b: &Path) -> bool {
    paths_equal_fs(&a.to_string_lossy(), &b.to_string_lossy(), cfg!(windows))
}

pub fn canonicalize_clean(p: &Path) -> std::io::Result<PathBuf> {
    let c = fs::canonicalize(p)?;
    #[cfg(windows)]
    {
        let s = c.to_string_lossy();
        if let Some(rest) = s.strip_prefix("\\\\?\\UNC\\") {
            return Ok(PathBuf::from(format!("\\\\{rest}")));
        }
        if let Some(rest) = s.strip_prefix("\\\\?\\") {
            return Ok(PathBuf::from(rest));
        }
    }
    Ok(c)
}

#[derive(Debug, Clone)]
pub struct GitContext {
    pub repo_root: PathBuf,
    pub git_dir: PathBuf,
    pub git_common_dir: PathBuf,
    pub real_common_dir: PathBuf,
    pub is_linked_worktree: bool,
}

fn run_raw_git_stdout(base: &Path, args: &[&str]) -> Result<Vec<String>, PrExit> {
    let mut full_args: Vec<&OsStr> = Vec::with_capacity(2 + args.len());
    full_args.push(OsStr::new("-C"));
    full_args.push(base.as_os_str());
    for a in args {
        full_args.push(OsStr::new(a));
    }
    let no_env: [(&str, &str); 0] = [];
    let Ok(res) = crate::process::run_command(
        crate::git::git_program(),
        &full_args,
        None,
        &no_env,
        &["MSYS2_ARG_CONV_EXCL"],
        None,
    ) else {
        return Ok(Vec::new());
    };
    if res.exit_code != 0 {
        return Ok(Vec::new());
    }
    let text = String::from_utf8_lossy(&res.stdout);
    Ok(text
        .lines()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect())
}

/// Resolves canonical Git repo/common directories and detects linked worktree execution.
pub fn resolve_git_context(raw_repo_root: Option<&str>) -> Result<GitContext, PrExit> {
    let base = match raw_repo_root {
        Some(r) if !r.is_empty() => {
            validate_safe_path(r, "--repo-root", true, true, MAX_FILE_BYTES)?
        }
        _ => {
            let cwd = std::env::current_dir().map_err(|e| {
                pr_fail(
                    "PR_FILE_GUARD",
                    format!("Cannot access cwd: {e}"),
                    EXIT_ERROR,
                    Vec::new(),
                )
            })?;
            validate_safe_path(&cwd.to_string_lossy(), "cwd", true, true, MAX_FILE_BYTES)?
        }
    };
    let lines = run_raw_git_stdout(
        &base,
        &[
            "rev-parse",
            "--show-toplevel",
            "--git-dir",
            "--git-common-dir",
        ],
    )?;
    if lines.len() < 3 {
        return Err(pr_fail(
            "PR_FILE_GUARD",
            format!(
                "Directory is not inside a Git working tree ({}); canonical state requires a Git repository root",
                base.display()
            ),
            EXIT_ERROR,
            Vec::new(),
        ));
    }
    let repo_root = validate_safe_path(&lines[0], "git-toplevel", true, true, MAX_FILE_BYTES)?;
    let git_dir_cand = resolve_unresolved_path(&base, &lines[1]);
    let git_dir = validate_safe_path(
        &git_dir_cand.to_string_lossy(),
        "git-dir",
        true,
        true,
        MAX_FILE_BYTES,
    )?;
    let common_cand = resolve_unresolved_path(&base, &lines[2]);
    let git_common_dir = validate_safe_path(
        &common_cand.to_string_lossy(),
        "git-common-dir",
        true,
        true,
        MAX_FILE_BYTES,
    )?;
    let real_git_dir = canonicalize_clean(&git_dir).map_err(|e| {
        pr_fail(
            "PR_FILE_GUARD",
            format!("Cannot canonicalize git-dir: {e}"),
            EXIT_ERROR,
            Vec::new(),
        )
    })?;
    let real_common_dir = canonicalize_clean(&git_common_dir).map_err(|e| {
        pr_fail(
            "PR_FILE_GUARD",
            format!("Cannot canonicalize git-common-dir: {e}"),
            EXIT_ERROR,
            Vec::new(),
        )
    })?;
    let is_linked_worktree = !same_fs_path(&real_git_dir, &real_common_dir);
    Ok(GitContext {
        repo_root,
        git_dir,
        git_common_dir,
        real_common_dir,
        is_linked_worktree,
    })
}

/// Blocks external PR mutations from worker/subagent contexts or linked worktrees.
pub fn assert_mutation_owner_allowed(
    git_ctx: &GitContext,
    action: &str,
    explicit_repo_root: Option<&str>,
) -> Result<(), PrExit> {
    let blocked = |reason: &str, msg: String| -> PrExit {
        pr_fail(
            "PR_MUTATION_OWNER_REQUIRED",
            msg,
            EXIT_BLOCKED,
            vec![
                (
                    "outcome".to_string(),
                    JsonValue::str("blocked_before_write"),
                ),
                ("mutated".to_string(), JsonValue::Bool(false)),
                ("action".to_string(), JsonValue::str(action)),
                ("reason".to_string(), JsonValue::str(reason)),
            ],
        )
    };
    let role = std::env::var("B3_PR_MUTATION_ROLE")
        .unwrap_or_default()
        .trim()
        .to_ascii_lowercase();
    let sub = std::env::var("B3_SUBAGENT")
        .unwrap_or_default()
        .trim()
        .to_ascii_lowercase();
    if role == "worker" || sub == "1" || sub == "true" {
        return Err(blocked(
            "worker_role_forbidden",
            format!(
                "Worker/subagent context cannot execute external PR mutation ({action}); return proposed payload/evidence to parent orchestrator"
            ),
        ));
    }
    if git_ctx.is_linked_worktree {
        return Err(blocked(
            "linked_worktree_forbidden",
            format!(
                "Linked Git worktree ({}) cannot execute external PR mutation ({action}); route mutations through the single-writer parent orchestrator",
                git_ctx.repo_root.display()
            ),
        ));
    }
    if explicit_repo_root.is_some_and(|s| !s.is_empty()) {
        let cwd_raw = std::env::current_dir().map_err(|e| {
            pr_fail(
                "PR_FILE_GUARD",
                format!("Cannot resolve cwd: {e}"),
                EXIT_ERROR,
                Vec::new(),
            )
        })?;
        let cwd = validate_safe_path(
            &cwd_raw.to_string_lossy(),
            "cwd",
            true,
            true,
            MAX_FILE_BYTES,
        )?;
        let cl = run_raw_git_stdout(&cwd, &["rev-parse", "--git-dir", "--git-common-dir"])?;
        if cl.len() >= 2 {
            let cwd_git = canonicalize_clean(&resolve_unresolved_path(&cwd, &cl[0])).ok();
            let cwd_common = canonicalize_clean(&resolve_unresolved_path(&cwd, &cl[1])).ok();
            if let (Some(cg), Some(cc)) = (cwd_git, cwd_common) {
                if !same_fs_path(&cg, &cc) && same_fs_path(&cc, &git_ctx.real_common_dir) {
                    return Err(blocked(
                        "linked_worktree_cwd_bypass",
                        format!(
                            "Process CWD is inside a linked worktree sharing {}; bypassing via --repo-root is forbidden for {action}",
                            git_ctx.git_common_dir.display()
                        ),
                    ));
                }
            }
        }
    }
    Ok(())
}

pub fn resolve_canonical_state_path(
    git_common_dir: &Path,
    repo_full: &str,
    pr_number: u64,
) -> Result<PathBuf, PrExit> {
    let mut safe_slug = String::with_capacity(repo_full.len());
    for ch in repo_full.to_ascii_lowercase().chars() {
        if ch.is_ascii_lowercase() || ch.is_ascii_digit() || matches!(ch, '.' | '_' | '-') {
            safe_slug.push(ch);
        } else {
            safe_slug.push_str("__");
        }
    }
    let state_path = git_common_dir
        .join("b3")
        .join("pr-feedback")
        .join(format!("{safe_slug}__pr-{pr_number}.state.json"));
    validate_safe_path(
        &state_path.to_string_lossy(),
        "canonical-state",
        false,
        false,
        MAX_FILE_BYTES,
    )
}

pub fn read_state_records(state_path: &Path) -> Result<Vec<JsonValue>, PrExit> {
    if !state_path.exists() {
        return Ok(Vec::new());
    }
    let raw = fs::read_to_string(state_path).map_err(|e| {
        pr_fail(
            "PR_FILE_GUARD",
            format!(
                "Cannot read canonical state file: {}",
                e.raw_os_error().unwrap_or(1)
            ),
            EXIT_ERROR,
            Vec::new(),
        )
    })?;
    let clean = raw.strip_prefix('\u{FEFF}').unwrap_or(&raw);
    let parsed = parse_json(clean).map_err(|_| {
        pr_fail(
            "PR_FILE_GUARD",
            "Corrupt JSON in canonical state file; refusing to overwrite or bypass reconciliation",
            EXIT_ERROR,
            Vec::new(),
        )
    })?;
    let JsonValue::Array(items) = parsed else {
        return Err(pr_fail(
            "PR_FILE_GUARD",
            "Canonical state file must contain a JSON array",
            EXIT_ERROR,
            Vec::new(),
        ));
    };
    Ok(items)
}

pub fn append_state_record(
    state_path: &Path,
    mut entry: Vec<(String, JsonValue)>,
    critical: bool,
) -> Result<bool, PrExit> {
    let inner = || -> Result<(), PrExit> {
        if let Some(dir) = state_path.parent() {
            if !dir.exists() {
                fs::create_dir_all(dir).map_err(|e| {
                    pr_fail(
                        "PR_FILE_GUARD",
                        format!("Failed to create canonical state dir: {e}"),
                        EXIT_ERROR,
                        Vec::new(),
                    )
                })?;
            }
        }
        assert_ancestors_safe(state_path, "canonical-state")?;
        let mut records = read_state_records(state_path)?;
        entry.push((
            "recorded_at_utc".to_string(),
            JsonValue::str(format_utc_iso8601_now()),
        ));
        records.push(JsonValue::Object(entry));
        let json_out = format!("{}\n", JsonValue::Array(records).to_json_pretty());

        let tmp_name = format!(
            "{}.tmp.{}.{}",
            state_path.display(),
            next_tmp_suffix(),
            unique_hex_token(6)
        );
        let tmp_path = PathBuf::from(&tmp_name);
        let mut opts = OpenOptions::new();
        opts.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            opts.mode(0o600);
        }
        let mut file = opts.open(&tmp_path).map_err(|e| {
            pr_fail(
                "PR_FILE_GUARD",
                format!("Failed to create canonical state temp file: {e}"),
                EXIT_ERROR,
                Vec::new(),
            )
        })?;
        if let Err(e) = file.write_all(json_out.as_bytes()) {
            let _ = fs::remove_file(&tmp_path);
            return Err(pr_fail(
                "PR_FILE_GUARD",
                format!("Failed to write canonical state temp file: {e}"),
                EXIT_ERROR,
                Vec::new(),
            ));
        }
        drop(file);
        if let Err(e) = fs::rename(&tmp_path, state_path) {
            let _ = fs::remove_file(&tmp_path);
            return Err(pr_fail(
                "PR_FILE_GUARD",
                format!("Failed to rename canonical state file: {e}"),
                EXIT_ERROR,
                Vec::new(),
            ));
        }
        Ok(())
    };
    match inner() {
        Ok(()) => Ok(true),
        Err(err) => {
            if critical {
                Err(err)
            } else {
                Ok(false)
            }
        }
    }
}

fn is_resolved_status(status: &str) -> bool {
    matches!(
        status,
        "PR_REPLY_OK"
            | "PR_RESOLVE_OK"
            | "PR_COMMENT_OK"
            | "PR_IDEMPOTENT_SKIP"
            | "PR_ALREADY_RESOLVED"
            | "RECONCILED_CONFIRMED"
            | "RECONCILED_ABSENT"
            | "RECONCILED_STALE"
    )
}

/// Returns all unresolved PENDING or reconciliation-required records for `(repo_full, pr_number)`.
pub fn get_unresolved_pending_records(
    records: &[JsonValue],
    repo_full: &str,
    pr_number: u64,
) -> Vec<JsonValue> {
    let mut by_op: Vec<(String, JsonValue)> = Vec::new();
    for r in records {
        let r_repo = r
            .get("repo")
            .and_then(JsonValue::as_str)
            .unwrap_or_default();
        let r_pr = r.get("pr").and_then(JsonValue::as_i64).unwrap_or(-1);
        if !r_repo.eq_ignore_ascii_case(repo_full) || r_pr != pr_number as i64 {
            continue;
        }
        let op_id = r
            .get("op_id")
            .and_then(JsonValue::as_str)
            .unwrap_or("__legacy__")
            .to_string();
        let status = r
            .get("status")
            .and_then(JsonValue::as_str)
            .unwrap_or_default();
        let recon_req = r
            .get("reconciliation_required")
            .and_then(JsonValue::as_bool)
            .unwrap_or(false);
        if status == "PENDING" || recon_req {
            if let Some(slot) = by_op.iter_mut().find(|(k, _)| *k == op_id) {
                slot.1 = r.clone();
            } else {
                by_op.push((op_id, r.clone()));
            }
        } else if is_resolved_status(status) {
            if let Some(pos) = by_op.iter().position(|(k, _)| *k == op_id) {
                by_op.remove(pos);
            }
        }
    }
    by_op.into_iter().map(|(_, v)| v).collect()
}

fn unique_hex_token(bytes_len: usize) -> String {
    let mut seed = Vec::with_capacity(64);
    seed.extend_from_slice(&std::process::id().to_le_bytes());
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    seed.extend_from_slice(&nanos.to_le_bytes());
    seed.extend_from_slice(next_tmp_suffix().as_bytes());
    let stack_addr = (&seed as *const Vec<u8>) as usize;
    seed.extend_from_slice(&stack_addr.to_le_bytes());
    let hex = sha256_bytes_hex(&seed);
    let need = bytes_len.saturating_mul(2).min(hex.len());
    hex[..need].to_string()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PidState {
    Alive,
    Dead,
    Unknown,
}

impl PidState {
    pub fn as_str(self) -> &'static str {
        match self {
            PidState::Alive => "ALIVE",
            PidState::Dead => "DEAD",
            PidState::Unknown => "UNKNOWN",
        }
    }
}

#[cfg(windows)]
#[link(name = "kernel32")]
extern "system" {
    fn GetComputerNameExW(name_type: u32, buffer: *mut u16, size: *mut u32) -> i32;
}

#[cfg(unix)]
extern "C" {
    fn gethostname(name: *mut std::ffi::c_char, len: usize) -> i32;
}

/// Returns the local DNS hostname matching `[Net.Dns]::GetHostName()` and Node's `os.hostname()`.
pub fn get_hostname() -> String {
    #[cfg(windows)]
    {
        let mut size: u32 = 256;
        let mut buf: Vec<u16> = vec![0u16; size as usize];
        // SAFETY: `ComputerNameDnsHostname` = 1; buffer length matches `size`.
        let ok = unsafe { GetComputerNameExW(1, buf.as_mut_ptr(), &mut size) };
        if ok != 0 && size > 0 {
            return String::from_utf16_lossy(&buf[..size as usize]);
        }
        if size > buf.len() as u32 {
            buf.resize(size as usize + 1, 0);
            // SAFETY: resized buffer fits required length + NUL.
            let ok2 = unsafe { GetComputerNameExW(1, buf.as_mut_ptr(), &mut size) };
            if ok2 != 0 && size > 0 {
                return String::from_utf16_lossy(&buf[..size as usize]);
            }
        }
        std::env::var("COMPUTERNAME").unwrap_or_default()
    }
    #[cfg(unix)]
    {
        let mut buf = [0u8; 256];
        // SAFETY: valid writable stack buffer for `gethostname`.
        let rc = unsafe { gethostname(buf.as_mut_ptr() as *mut std::ffi::c_char, buf.len()) };
        if rc == 0 {
            let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
            return String::from_utf8_lossy(&buf[..end]).to_string();
        }
        std::env::var("HOSTNAME").unwrap_or_default()
    }
}

/// Probes whether `pid` on the local host is alive, confirmed dead, or indeterminate.
pub fn is_pid_alive_same_host(pid: i64) -> PidState {
    match probe_pid_liveness(pid) {
        PidLiveness::Alive => PidState::Alive,
        PidLiveness::Dead => PidState::Dead,
        PidLiveness::Unknown => PidState::Unknown,
    }
}

fn create_exclusive_file(path: &Path, content: &str) -> std::io::Result<()> {
    let mut opts = OpenOptions::new();
    opts.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600);
    }
    let mut f = opts.open(path)?;
    f.write_all(content.as_bytes())
}

struct OwnedTokenFileGuard {
    path: PathBuf,
    token: String,
}

impl Drop for OwnedTokenFileGuard {
    fn drop(&mut self) {
        if let Ok(raw) = fs::read_to_string(&self.path) {
            if raw.contains(&self.token) {
                let _ = fs::remove_file(&self.path);
            }
        }
    }
}

fn now_millis() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn lock_state_name(state_path: &Path) -> String {
    state_path
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("state")
        .to_string()
}

fn is_symlink_file(path: &Path) -> bool {
    match fs::symlink_metadata(path) {
        Ok(m) => m.file_type().is_symlink() || is_reparse_or_symlink(path),
        Err(_) => false,
    }
}

fn read_lock_json(path: &Path) -> Option<JsonValue> {
    let raw = fs::read_to_string(path).ok()?;
    parse_json(&raw).ok()
}

/// Executes `f` under an atomic exclusive lockfile with strict PID-dead-only reclamation.
pub fn with_state_lock<T, F>(state_path: &Path, op_name: &str, f: F) -> Result<T, PrExit>
where
    F: FnOnce() -> Result<T, PrExit>,
{
    if let Some(dir) = state_path.parent() {
        if !dir.exists() {
            fs::create_dir_all(dir).map_err(|e| {
                pr_fail(
                    "PR_FILE_GUARD",
                    format!("Unable to create state directory: {e}"),
                    EXIT_ERROR,
                    Vec::new(),
                )
            })?;
        }
    }
    assert_ancestors_safe(state_path, "canonical-state")?;

    let lock_path = PathBuf::from(format!("{}.lock", state_path.display()));
    let reclaim_lock_path = PathBuf::from(format!("{}.reclaim", lock_path.display()));
    let lock_token = unique_hex_token(16);
    let host = get_hostname();
    let base_name = lock_state_name(state_path);
    let lock_body = format!(
        "{}\n",
        JsonValue::Object(vec![
            (
                "pid".to_string(),
                JsonValue::num_u64(std::process::id() as u64)
            ),
            ("host".to_string(), JsonValue::str(&host)),
            ("token".to_string(), JsonValue::str(&lock_token)),
            ("op".to_string(), JsonValue::str(op_name)),
            ("started_at".to_string(), JsonValue::num_u64(now_millis())),
        ])
        .to_json_string()
    );

    if let Err(err) = create_exclusive_file(&lock_path, &lock_body) {
        if err.kind() != ErrorKind::AlreadyExists {
            return Err(pr_fail(
                "PR_FILE_GUARD",
                format!(
                    "Unable to create state lock: {}",
                    err.raw_os_error().unwrap_or(1)
                ),
                EXIT_ERROR,
                Vec::new(),
            ));
        }
        if is_symlink_file(&lock_path) {
            return Err(pr_fail(
                "PR_FILE_GUARD",
                format!("Symlink lock file rejected: {}", lock_path.display()),
                EXIT_ERROR,
                Vec::new(),
            ));
        }
        let existing = read_lock_json(&lock_path);
        let ex_host = existing
            .as_ref()
            .and_then(|v| v.get("host"))
            .and_then(JsonValue::as_str)
            .unwrap_or("");
        let ex_token = existing
            .as_ref()
            .and_then(|v| v.get("token"))
            .and_then(JsonValue::as_str)
            .unwrap_or("");
        let ex_pid = existing
            .as_ref()
            .and_then(|v| v.get("pid"))
            .and_then(JsonValue::as_i64);
        let same_host = !ex_host.is_empty() && ex_host == host;
        let liveness = if same_host {
            ex_pid.map_or(PidState::Unknown, is_pid_alive_same_host)
        } else {
            PidState::Unknown
        };
        if liveness != PidState::Dead || ex_token.is_empty() {
            let pid_disp = ex_pid.map_or_else(|| "unknown".to_string(), |p| p.to_string());
            let host_disp = if ex_host.is_empty() {
                "unknown"
            } else {
                ex_host
            };
            return Err(pr_fail(
                "PR_CONCURRENT_LOCK",
                format!(
                    "Active or unverified lock held on {base_name} (host={host_disp}, pid={pid_disp}, state={})",
                    liveness.as_str()
                ),
                EXIT_BLOCKED,
                vec![
                    (
                        "outcome".to_string(),
                        JsonValue::str("blocked_before_write"),
                    ),
                    ("mutated".to_string(), JsonValue::Bool(false)),
                ],
            ));
        }

        let reclaim_token = unique_hex_token(16);
        let reclaim_body = format!(
            "{}\n",
            JsonValue::Object(vec![
                (
                    "pid".to_string(),
                    JsonValue::num_u64(std::process::id() as u64)
                ),
                ("host".to_string(), JsonValue::str(&host)),
                ("token".to_string(), JsonValue::str(&reclaim_token)),
                ("op".to_string(), JsonValue::str(op_name)),
            ])
            .to_json_string()
        );
        if let Err(r_err) = create_exclusive_file(&reclaim_lock_path, &reclaim_body) {
            if is_symlink_file(&reclaim_lock_path) {
                return Err(pr_fail(
                    "PR_FILE_GUARD",
                    format!(
                        "Symlink reclaim lock rejected: {}",
                        reclaim_lock_path.display()
                    ),
                    EXIT_ERROR,
                    Vec::new(),
                ));
            }
            if r_err.kind() != ErrorKind::AlreadyExists {
                return Err(pr_fail(
                    "PR_FILE_GUARD",
                    format!(
                        "Unable to create reclaim mutex: {}",
                        r_err.raw_os_error().unwrap_or(1)
                    ),
                    EXIT_ERROR,
                    Vec::new(),
                ));
            }
            return Err(pr_fail(
                "PR_CONCURRENT_LOCK",
                format!("Concurrent lock reclamation in progress for {base_name}"),
                EXIT_BLOCKED,
                vec![
                    (
                        "outcome".to_string(),
                        JsonValue::str("blocked_before_write"),
                    ),
                    ("mutated".to_string(), JsonValue::Bool(false)),
                ],
            ));
        }
        let _reclaim_guard = OwnedTokenFileGuard {
            path: reclaim_lock_path.clone(),
            token: reclaim_token,
        };

        if is_symlink_file(&lock_path) {
            return Err(pr_fail(
                "PR_FILE_GUARD",
                format!("Symlink lock file rejected: {}", lock_path.display()),
                EXIT_ERROR,
                Vec::new(),
            ));
        }
        let recheck = read_lock_json(&lock_path);
        let still_same_dead = recheck.as_ref().is_some_and(|rc| {
            let rc_token = rc.get("token").and_then(JsonValue::as_str).unwrap_or("");
            let rc_host = rc.get("host").and_then(JsonValue::as_str).unwrap_or("");
            let rc_pid = rc.get("pid").and_then(JsonValue::as_i64);
            rc_token == ex_token
                && rc_host == host
                && rc_pid == ex_pid
                && rc_pid.is_some_and(|p| is_pid_alive_same_host(p) == PidState::Dead)
        });
        if !still_same_dead {
            return Err(pr_fail(
                "PR_CONCURRENT_LOCK",
                format!("Concurrent operation already reclaimed or replaced lock on {base_name}"),
                EXIT_BLOCKED,
                vec![
                    (
                        "outcome".to_string(),
                        JsonValue::str("blocked_before_write"),
                    ),
                    ("mutated".to_string(), JsonValue::Bool(false)),
                ],
            ));
        }
        let dead_copy = PathBuf::from(format!(
            "{}.dead.{}.{}",
            lock_path.display(),
            std::process::id(),
            &lock_token[..8.min(lock_token.len())]
        ));
        if fs::rename(&lock_path, &dead_copy).is_err() {
            return Err(pr_fail(
                "PR_CONCURRENT_LOCK",
                format!("Concurrent operation holds lock on {base_name}"),
                EXIT_BLOCKED,
                vec![
                    (
                        "outcome".to_string(),
                        JsonValue::str("blocked_before_write"),
                    ),
                    ("mutated".to_string(), JsonValue::Bool(false)),
                ],
            ));
        }
        let _ = fs::remove_file(&dead_copy);
        if create_exclusive_file(&lock_path, &lock_body).is_err() {
            return Err(pr_fail(
                "PR_CONCURRENT_LOCK",
                format!("Concurrent operation holds lock on {base_name}"),
                EXIT_BLOCKED,
                vec![
                    (
                        "outcome".to_string(),
                        JsonValue::str("blocked_before_write"),
                    ),
                    ("mutated".to_string(), JsonValue::Bool(false)),
                ],
            ));
        }
    }

    let _lock_guard = OwnedTokenFileGuard {
        path: lock_path,
        token: lock_token,
    };
    f()
}
