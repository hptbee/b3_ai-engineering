use std::collections::BTreeMap;
use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};

use crate::error::{fail, B3Error};
use crate::fs::{
    has_control_chars, is_reparse_or_symlink, resolve_unresolved_path, sha256_bytes_hex,
    sort_ordinal,
};

/// Normalizes `raw` lexically against CWD, trimming trailing slashes and uppercasing Windows drive letters.
pub fn normalize_path_str(raw: &str) -> Result<String, B3Error> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Ok(String::new());
    }
    let cwd = std::env::current_dir()
        .map_err(|e| fail(format!("ADAPTER_FAIL: cannot resolve cwd: {e}"), 1))?;
    let abs = resolve_unresolved_path(&cwd, trimmed);
    Ok(normalize_abs_path_str(&abs))
}

pub fn normalize_abs_path_str(p: &Path) -> String {
    let mut s = p.to_string_lossy().into_owned();
    #[cfg(windows)]
    {
        if let Some(rest) = s.strip_prefix("\\\\?\\UNC\\") {
            s = format!("\\\\{rest}");
        } else if let Some(rest) = s.strip_prefix("\\\\?\\") {
            s = rest.to_string();
        } else if let Some(rest) = s.strip_prefix("\\??\\") {
            s = rest.to_string();
        }
        s = s.replace('/', "\\");
    }
    let is_win_root = cfg!(windows)
        && s.len() == 3
        && s.as_bytes()[0].is_ascii_alphabetic()
        && s.as_bytes()[1] == b':'
        && (s.as_bytes()[2] == b'\\' || s.as_bytes()[2] == b'/');
    if s != "/" && !is_win_root {
        while s.ends_with('\\') || s.ends_with('/') {
            s.pop();
        }
    }
    #[cfg(windows)]
    {
        if s.len() >= 2 && s.as_bytes()[0].is_ascii_lowercase() && s.as_bytes()[1] == b':' {
            let upper = (s.as_bytes()[0] as char).to_ascii_uppercase();
            s = format!("{upper}{}", &s[1..]);
        }
    }
    s
}

pub fn to_forward_path(p: &Path) -> String {
    let mut s = normalize_abs_path_str(p).replace('\\', "/");
    let b = s.as_bytes();
    if b.len() >= 2 && b[0].is_ascii_lowercase() && b[1] == b':' {
        let upper = (b[0] as char).to_ascii_uppercase();
        s = format!("{upper}{}", &s[1..]);
    }
    s
}

pub fn write_utf8_no_bom_lf(path: &Path, content: &str) -> Result<(), B3Error> {
    let lf = content.replace("\r\n", "\n").replace('\r', "\n");
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() && !parent.exists() {
            fs::create_dir_all(parent).map_err(|e| {
                fail(
                    format!(
                        "ADAPTER_FAIL: cannot create parent dir {}: {e}",
                        parent.display()
                    ),
                    1,
                )
            })?;
        }
    }
    fs::write(path, lf.as_bytes()).map_err(|e| {
        fail(
            format!("ADAPTER_FAIL: cannot write {}: {e}", path.display()),
            1,
        )
    })
}

pub fn text_sha256_lf(text: &str) -> String {
    let lf = text.replace("\r\n", "\n").replace('\r', "\n");
    sha256_bytes_hex(lf.as_bytes())
}

pub fn file_sha256(path: &Path) -> Result<String, B3Error> {
    let bytes = fs::read(path).map_err(|e| {
        fail(
            format!("ADAPTER_FAIL: cannot read {}: {e}", path.display()),
            1,
        )
    })?;
    Ok(sha256_bytes_hex(&bytes))
}

pub fn path_exists_or_link(p: &Path) -> bool {
    fs::symlink_metadata(p).is_ok() || is_reparse_or_symlink(p)
}

pub fn is_reparse_link(p: &Path) -> bool {
    is_reparse_or_symlink(p)
}

pub fn assert_regular_dir_or_missing(dir_path: &Path, label: &str) -> Result<(), B3Error> {
    match fs::symlink_metadata(dir_path) {
        Ok(meta) => {
            if meta.file_type().is_symlink() || is_reparse_or_symlink(dir_path) {
                let desc = if label.is_empty() {
                    String::new()
                } else {
                    format!(" {label}")
                };
                return Err(fail(
                    format!(
                        "refusing to traverse link directory{desc}: {}",
                        dir_path.display()
                    ),
                    1,
                ));
            }
            if !meta.is_dir() {
                let desc = if label.is_empty() {
                    " directory".to_string()
                } else {
                    format!(" {label}")
                };
                return Err(fail(
                    format!(
                        "existing non-directory path blocks{desc}: {}",
                        dir_path.display()
                    ),
                    1,
                ));
            }
            Ok(())
        }
        Err(e) if e.kind() == ErrorKind::NotFound => Ok(()),
        Err(e) => Err(fail(
            format!("cannot inspect directory {}: {e}", dir_path.display()),
            1,
        )),
    }
}

pub fn assert_regular_file_or_missing(file_path: &Path, label: &str) -> Result<(), B3Error> {
    match fs::symlink_metadata(file_path) {
        Ok(meta) => {
            if meta.file_type().is_symlink() || is_reparse_or_symlink(file_path) {
                let desc = if label.is_empty() {
                    file_path.display().to_string()
                } else {
                    label.to_string()
                };
                return Err(fail(
                    format!("existing link blocks {desc}: {}", file_path.display()),
                    1,
                ));
            }
            if !meta.is_file() {
                let desc = if label.is_empty() {
                    file_path.display().to_string()
                } else {
                    label.to_string()
                };
                return Err(fail(
                    format!(
                        "existing non-file path blocks {desc}: {}",
                        file_path.display()
                    ),
                    1,
                ));
            }
            Ok(())
        }
        Err(e) if e.kind() == ErrorKind::NotFound => Ok(()),
        Err(e) => Err(fail(
            format!("cannot inspect file {}: {e}", file_path.display()),
            1,
        )),
    }
}

/// Removes a symlink or NTFS junction directory without deleting the target's contents.
pub fn remove_link_only(link_path: &Path) -> Result<(), B3Error> {
    let Ok(meta) = fs::symlink_metadata(link_path) else {
        return Ok(());
    };
    if !meta.file_type().is_symlink() && !is_reparse_or_symlink(link_path) {
        return Err(fail(
            format!("refusing to remove non-link entry: {}", link_path.display()),
            1,
        ));
    }
    if cfg!(windows) {
        if meta.is_dir() {
            fs::remove_dir(link_path).map_err(|e| {
                fail(
                    format!(
                        "could not remove link directory {}: {e}",
                        link_path.display()
                    ),
                    1,
                )
            })?;
        } else {
            fs::remove_file(link_path).map_err(|e| {
                fail(
                    format!("could not remove link file {}: {e}", link_path.display()),
                    1,
                )
            })?;
        }
        if path_exists_or_link(link_path) {
            return Err(fail(
                format!("could not remove link directory: {}", link_path.display()),
                1,
            ));
        }
    } else {
        fs::remove_file(link_path).map_err(|e| {
            fail(
                format!("could not remove link {}: {e}", link_path.display()),
                1,
            )
        })?;
    }
    Ok(())
}

#[cfg(windows)]
#[link(name = "kernel32")]
extern "system" {
    fn CreateFileW(
        lp_file_name: *const u16,
        dw_desired_access: u32,
        dw_share_mode: u32,
        lp_security_attributes: *const core::ffi::c_void,
        dw_creation_disposition: u32,
        dw_flags_and_attributes: u32,
        h_template_file: *mut core::ffi::c_void,
    ) -> *mut core::ffi::c_void;
    fn DeviceIoControl(
        h_device: *mut core::ffi::c_void,
        dw_io_control_code: u32,
        lp_in_buffer: *const core::ffi::c_void,
        n_in_buffer_size: u32,
        lp_out_buffer: *mut core::ffi::c_void,
        n_out_buffer_size: u32,
        lp_bytes_returned: *mut u32,
        lp_overlapped: *mut core::ffi::c_void,
    ) -> i32;
    fn CloseHandle(h_object: *mut core::ffi::c_void) -> i32;
}

/// Creates a directory link (NTFS junction on Windows without cmd.exe, symlink on Unix).
pub fn create_dir_link(dest_path: &Path, target_path: &Path) -> Result<(), B3Error> {
    if let Some(parent) = dest_path.parent() {
        if !parent.as_os_str().is_empty() && !parent.exists() {
            fs::create_dir_all(parent).map_err(|e| {
                fail(
                    format!(
                        "failed to create parent directory {}: {e}",
                        parent.display()
                    ),
                    1,
                )
            })?;
        }
    }

    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;

        const GENERIC_WRITE: u32 = 0x4000_0000;
        const FILE_SHARE_ALL: u32 = 0x0000_0007;
        const OPEN_EXISTING: u32 = 3;
        const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;
        const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
        const FSCTL_SET_REPARSE_POINT: u32 = 0x0009_00A4;
        const IO_REPARSE_TAG_MOUNT_POINT: u32 = 0xA000_0003;
        const INVALID_HANDLE_VALUE: isize = -1;

        let target_norm = normalize_abs_path_str(target_path);
        let sub_name = format!("\\??\\{target_norm}");
        let print_name = target_norm;

        let sub_utf16: Vec<u16> = sub_name.encode_utf16().collect();
        let print_utf16: Vec<u16> = print_name.encode_utf16().collect();
        let sub_bytes = (sub_utf16.len() * 2) as u16;
        let print_bytes = (print_utf16.len() * 2) as u16;
        let reparse_data_len: u16 = 8u16 + sub_bytes + 2 + print_bytes + 2;
        let total_len = 8usize + reparse_data_len as usize;

        let mut buf = Vec::with_capacity(total_len);
        buf.extend_from_slice(&IO_REPARSE_TAG_MOUNT_POINT.to_le_bytes());
        buf.extend_from_slice(&reparse_data_len.to_le_bytes());
        buf.extend_from_slice(&0u16.to_le_bytes()); // Reserved
        buf.extend_from_slice(&0u16.to_le_bytes()); // SubstituteNameOffset
        buf.extend_from_slice(&sub_bytes.to_le_bytes());
        buf.extend_from_slice(&(sub_bytes + 2).to_le_bytes()); // PrintNameOffset
        buf.extend_from_slice(&print_bytes.to_le_bytes());
        for w in &sub_utf16 {
            buf.extend_from_slice(&w.to_le_bytes());
        }
        buf.extend_from_slice(&0u16.to_le_bytes());
        for w in &print_utf16 {
            buf.extend_from_slice(&w.to_le_bytes());
        }
        buf.extend_from_slice(&0u16.to_le_bytes());

        fs::create_dir(dest_path).map_err(|e| {
            fail(
                format!(
                    "failed to create junction dir {} -> {}: {e}",
                    dest_path.display(),
                    target_path.display()
                ),
                1,
            )
        })?;

        let mut dest_wide: Vec<u16> = dest_path.as_os_str().encode_wide().collect();
        dest_wide.push(0);

        // SAFETY: `dest_wide` is NUL-terminated UTF-16; handle is closed cleanly on every path.
        unsafe {
            let handle = CreateFileW(
                dest_wide.as_ptr(),
                GENERIC_WRITE,
                FILE_SHARE_ALL,
                core::ptr::null(),
                OPEN_EXISTING,
                FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
                core::ptr::null_mut(),
            );
            if handle.is_null() || handle as isize == INVALID_HANDLE_VALUE {
                let err = std::io::Error::last_os_error();
                let _ = fs::remove_dir(dest_path);
                return Err(fail(
                    format!(
                        "failed to open junction {} for reparse: {err}",
                        dest_path.display()
                    ),
                    1,
                ));
            }
            let mut returned: u32 = 0;
            let ok = DeviceIoControl(
                handle,
                FSCTL_SET_REPARSE_POINT,
                buf.as_ptr() as *const core::ffi::c_void,
                buf.len() as u32,
                core::ptr::null_mut(),
                0,
                &mut returned,
                core::ptr::null_mut(),
            );
            CloseHandle(handle);
            if ok == 0 {
                let err = std::io::Error::last_os_error();
                let _ = fs::remove_dir(dest_path);
                return Err(fail(
                    format!(
                        "failed to set NTFS junction {} -> {}: {err}",
                        dest_path.display(),
                        target_path.display()
                    ),
                    1,
                ));
            }
        }
        Ok(())
    }

    #[cfg(not(windows))]
    {
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(target_path, dest_path).map_err(|e| {
                fail(
                    format!(
                        "failed to create symlink {} -> {}: {e}",
                        dest_path.display(),
                        target_path.display()
                    ),
                    1,
                )
            })
        }
        #[cfg(not(unix))]
        {
            let _ = (dest_path, target_path);
            Err(fail(
                "symlink/junction creation unsupported on this platform",
                1,
            ))
        }
    }
}

pub fn test_link_target(link_path: &Path, expected_dir: &Path, raw_target_only: bool) -> bool {
    if !is_reparse_link(link_path) {
        return false;
    }
    if !raw_target_only && !fs::metadata(link_path).is_ok_and(|m| m.is_dir()) {
        return false;
    }
    let Ok(raw_target) = fs::read_link(link_path) else {
        return false;
    };
    let abs_cand = if raw_target.is_absolute() {
        raw_target
    } else if let Some(parent) = link_path.parent() {
        resolve_unresolved_path(parent, &raw_target.to_string_lossy())
    } else {
        raw_target
    };
    let cand_norm = normalize_abs_path_str(&abs_cand);
    let exp_norm = normalize_abs_path_str(expected_dir);
    if cand_norm.is_empty() {
        return false;
    }
    if cfg!(windows) {
        cand_norm.eq_ignore_ascii_case(&exp_norm)
    } else {
        cand_norm == exp_norm
    }
}

pub fn has_active_path(p: &Path) -> bool {
    let Ok(meta) = fs::symlink_metadata(p) else {
        return is_reparse_or_symlink(p);
    };
    if meta.file_type().is_symlink() || is_reparse_or_symlink(p) {
        return true;
    }
    if meta.is_dir() {
        return fs::read_dir(p).ok().and_then(|mut it| it.next()).is_some();
    }
    true
}

pub fn get_skill_name_from_file(skill_md: &Path) -> String {
    if let Ok(raw) = fs::read_to_string(skill_md) {
        let norm = raw.replace("\r\n", "\n").replace('\r', "\n");
        let lines: Vec<&str> = norm.split('\n').collect();
        if lines.len() >= 3 && lines[0].trim() == "---" {
            for line in lines.iter().skip(1) {
                let t = line.trim();
                if t == "---" {
                    break;
                }
                if let Some(rest) = t.strip_prefix("name:") {
                    let candidate = rest.trim();
                    if !candidate.is_empty()
                        && candidate
                            .bytes()
                            .all(|b| matches!(b, b'a'..=b'z' | b'0'..=b'9' | b'-'))
                    {
                        return candidate.to_string();
                    }
                }
            }
        }
    }
    skill_md
        .parent()
        .and_then(|p| p.file_name())
        .and_then(|n| n.to_str())
        .unwrap_or("")
        .to_string()
}

/// Scans `root_dir` recursively for `SKILL.md` files (in ordinal path order) and registers them in `all_map`.
pub fn add_canonical_skills(
    root_dir: &Path,
    all_map: &mut BTreeMap<String, PathBuf>,
) -> Result<usize, B3Error> {
    if !root_dir.is_dir() {
        return Ok(0);
    }
    let mut found_files = Vec::new();
    collect_skill_md_files(root_dir, &mut found_files)?;
    let path_strs = sort_ordinal(
        found_files.iter().map(|p| p.to_string_lossy().into_owned()),
        false,
    );
    let count = path_strs.len();
    for sf_str in path_strs {
        let sf = PathBuf::from(&sf_str);
        let sname = get_skill_name_from_file(&sf);
        let Some(parent_dir) = sf.parent() else {
            continue;
        };
        let norm_dir = PathBuf::from(normalize_abs_path_str(parent_dir));
        if let Some(prev) = all_map.get(&sname) {
            return Err(fail(
                format!(
                    "duplicate canonical skill name '{sname}': {} and {}",
                    prev.display(),
                    sf.display()
                ),
                1,
            ));
        }
        all_map.insert(sname, norm_dir);
    }
    Ok(count)
}

pub fn collect_skill_md_files(dir: &Path, out: &mut Vec<PathBuf>) -> Result<(), B3Error> {
    let entries = fs::read_dir(dir).map_err(|e| {
        fail(
            format!("ADAPTER_FAIL: cannot scan {}: {e}", dir.display()),
            1,
        )
    })?;
    for entry in entries.flatten() {
        let p = entry.path();
        if entry.file_type().is_ok_and(|ft| ft.is_dir()) {
            collect_skill_md_files(&p, out)?;
        } else if entry.file_name() == "SKILL.md" && entry.file_type().is_ok_and(|ft| ft.is_file())
        {
            out.push(p);
        }
    }
    Ok(())
}

pub fn resolve_user_home_dir(override_home: Option<&Path>) -> PathBuf {
    if let Some(h) = override_home {
        return PathBuf::from(normalize_abs_path_str(h));
    }
    let home_env = std::env::var("USERPROFILE")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .or_else(|| std::env::var("HOME").ok().filter(|s| !s.trim().is_empty()))
        .unwrap_or_else(|| ".".to_string());
    PathBuf::from(normalize_abs_path_str(Path::new(home_env.trim())))
}

/// Initializes optional personal `~/.b3/models.md` from `config/models.example.md`.
pub fn initialize_personal_models_file(
    b3_home: &Path,
    user_home: Option<&Path>,
    dry_run: bool,
    non_fatal: bool,
) -> Result<String, B3Error> {
    if std::env::var("B3_SKIP_MODEL_INIT").ok().as_deref() == Some("1") {
        return Ok("skipped".to_string());
    }
    let template_md = b3_home.join("config").join("models.example.md");
    if !template_md.is_file() {
        return Ok("no-template".to_string());
    }
    let dest = match std::env::var("B3_MODELS_PERSONAL") {
        Ok(val) if !val.trim().is_empty() && !has_control_chars(val.trim()) => {
            PathBuf::from(val.trim())
        }
        _ => resolve_user_home_dir(user_home)
            .join(".b3")
            .join("models.md"),
    };
    let dest_str = dest.to_string_lossy().into_owned();
    if path_exists_or_link(&dest) {
        return Ok(format!("kept:{dest_str}"));
    }
    if dry_run {
        return Ok(format!("dry-run:{dest_str}"));
    }
    if let Some(parent) = dest.parent() {
        if let Err(e) = fs::create_dir_all(parent) {
            if path_exists_or_link(&dest) {
                return Ok(format!("kept:{dest_str}"));
            }
            if non_fatal {
                eprintln!(
                    "WARNING: optional model preferences could not be initialized at {dest_str} : {e}"
                );
                return Ok(format!("error:{dest_str}"));
            }
            return Err(fail(
                format!("ADAPTER_FAIL: cannot create {}: {e}", parent.display()),
                1,
            ));
        }
    }
    match fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&dest)
    {
        Ok(mut f) => {
            let content = fs::read(&template_md).map_err(|e| {
                fail(
                    format!("ADAPTER_FAIL: cannot read {}: {e}", template_md.display()),
                    1,
                )
            })?;
            use std::io::Write;
            if let Err(e) = f.write_all(&content) {
                if non_fatal {
                    eprintln!(
                        "WARNING: optional model preferences could not be initialized at {dest_str} : {e}"
                    );
                    return Ok(format!("error:{dest_str}"));
                }
                return Err(fail(
                    format!("ADAPTER_FAIL: cannot write {dest_str}: {e}"),
                    1,
                ));
            }
            Ok(format!("created:{dest_str}"))
        }
        Err(e) if e.kind() == ErrorKind::AlreadyExists => Ok(format!("kept:{dest_str}")),
        Err(e) => {
            if path_exists_or_link(&dest) {
                return Ok(format!("kept:{dest_str}"));
            }
            if non_fatal {
                eprintln!(
                    "WARNING: optional model preferences could not be initialized at {dest_str} : {e}"
                );
                return Ok(format!("error:{dest_str}"));
            }
            Err(fail(
                format!("ADAPTER_FAIL: cannot initialize {dest_str}: {e}"),
                1,
            ))
        }
    }
}

pub fn format_personal_models_status(
    b3_home: &Path,
    status: &str,
    emit_error: bool,
) -> Option<String> {
    if let Some(rest) = status.strip_prefix("kept:") {
        Some(format!("model_preferences={rest} (kept existing)"))
    } else if let Some(rest) = status.strip_prefix("dry-run:") {
        let tmpl = b3_home.join("config").join("models.example.md");
        Some(format!(
            "dry-run: initialize model_preferences={rest} from {}",
            tmpl.display()
        ))
    } else if let Some(rest) = status.strip_prefix("created:") {
        Some(format!("model_preferences={rest} (created from example)"))
    } else if emit_error && status.starts_with("error:") {
        Some(format!("model_preferences={status}"))
    } else {
        None
    }
}

pub fn resolve_b3_home_dir(b3_home_arg: &str, default_root: &Path) -> Result<PathBuf, B3Error> {
    let raw = if !b3_home_arg.trim().is_empty() {
        normalize_path_str(b3_home_arg.trim())?
    } else {
        normalize_abs_path_str(default_root)
    };
    let cand = PathBuf::from(&raw);
    if !cand.is_dir() {
        return Err(fail(format!("B3Home directory not found: {raw}"), 1));
    }
    let norm = normalize_abs_path_str(&cand);
    Ok(PathBuf::from(norm))
}
