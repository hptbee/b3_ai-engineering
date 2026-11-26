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
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;
        if (meta.file_attributes() & FILE_ATTRIBUTE_DIRECTORY) != 0 {
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
    }
    #[cfg(not(windows))]
    {
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

#[derive(Debug, Clone)]
pub struct SplitFrontmatter {
    pub has_frontmatter: bool,
    pub frontmatter: String,
    pub fm_lines: Vec<String>,
    pub body: String,
}

/// Parses optional/required YAML frontmatter cleanly with LF line endings.
pub fn split_yaml_frontmatter(
    file_path: &Path,
    require_frontmatter: bool,
) -> Result<SplitFrontmatter, B3Error> {
    let raw_bytes = fs::read(file_path).map_err(|e| {
        fail(
            format!("cannot read markdown {}: {e}", file_path.display()),
            1,
        )
    })?;
    let raw_str = String::from_utf8_lossy(&raw_bytes);
    let clean = raw_str.strip_prefix('\u{FEFF}').unwrap_or(&raw_str);
    let norm = clean.replace("\r\n", "\n").replace('\r', "\n");
    let lines: Vec<&str> = norm.split('\n').collect();
    if lines.len() >= 3 && lines[0].trim() == "---" {
        let end_idx = lines.iter().enumerate().skip(1).find_map(|(i, l)| {
            if l.trim() == "---" {
                Some(i)
            } else {
                None
            }
        });
        let Some(end_i) = end_idx else {
            if require_frontmatter {
                return Err(fail(
                    format!(
                        "canonical markdown unclosed YAML frontmatter: {}",
                        file_path.display()
                    ),
                    1,
                ));
            }
            return Ok(SplitFrontmatter {
                has_frontmatter: false,
                frontmatter: String::new(),
                fm_lines: Vec::new(),
                body: norm.trim().to_string(),
            });
        };
        let fm_lines: Vec<String> = lines[..=end_i].iter().map(|s| (*s).to_string()).collect();
        let frontmatter = fm_lines.join("\n");
        let body = if end_i + 1 < lines.len() {
            lines[end_i + 1..]
                .join("\n")
                .trim_start_matches('\n')
                .trim_end()
                .to_string()
        } else {
            String::new()
        };
        return Ok(SplitFrontmatter {
            has_frontmatter: true,
            frontmatter,
            fm_lines,
            body,
        });
    }
    if require_frontmatter {
        return Err(fail(
            format!(
                "canonical markdown missing YAML frontmatter: {}",
                file_path.display()
            ),
            1,
        ));
    }
    Ok(SplitFrontmatter {
        has_frontmatter: false,
        frontmatter: String::new(),
        fm_lines: Vec::new(),
        body: norm.trim().to_string(),
    })
}

pub fn get_canonical_markdown_names(dir_path: &Path) -> Vec<String> {
    if !dir_path.is_dir() {
        return Vec::new();
    }
    let mut full_paths = Vec::new();
    if let Ok(rd) = fs::read_dir(dir_path) {
        for entry in rd.flatten() {
            if !entry.file_type().is_ok_and(|ft| ft.is_file()) {
                continue;
            }
            let name = entry.file_name().to_string_lossy().into_owned();
            if name != "README.md" && name.ends_with(".md") {
                full_paths.push(entry.path().to_string_lossy().into_owned());
            }
        }
    }
    let sorted_paths = sort_ordinal(full_paths, false);
    sorted_paths
        .into_iter()
        .filter_map(|p| {
            Path::new(&p)
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
        })
        .collect()
}

pub fn add_canonical_skills_with_bucket(
    root_dir: &Path,
    all_map: &mut BTreeMap<String, PathBuf>,
    mut bucket_map: Option<&mut BTreeMap<String, PathBuf>>,
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
        all_map.insert(sname.clone(), norm_dir.clone());
        if let Some(b) = bucket_map.as_deref_mut() {
            b.insert(sname, norm_dir);
        }
    }
    Ok(count)
}

pub fn get_skill_overlaps(root_dir: &Path, skill_names: &[String]) -> Vec<String> {
    if !root_dir.is_dir() {
        return Vec::new();
    }
    let mut overlaps = Vec::new();
    for sn in skill_names {
        let p = root_dir.join(sn);
        if path_exists_or_link(&p) {
            overlaps.push(sn.clone());
        }
    }
    overlaps
}

pub fn remove_dir_tree_safely(dir_path: &Path) -> Result<(), B3Error> {
    let Ok(meta) = fs::symlink_metadata(dir_path) else {
        return Ok(());
    };
    if meta.file_type().is_symlink() || is_reparse_link(dir_path) {
        return Err(fail(
            format!(
                "refusing recursive delete of link path: {}",
                dir_path.display()
            ),
            1,
        ));
    }
    if !meta.is_dir() {
        fs::remove_file(dir_path)
            .map_err(|e| fail(format!("cannot remove file {}: {e}", dir_path.display()), 1))?;
        return Ok(());
    }
    let entries = fs::read_dir(dir_path).map_err(|e| {
        fail(
            format!("cannot read directory {}: {e}", dir_path.display()),
            1,
        )
    })?;
    for entry in entries.flatten() {
        let p = entry.path();
        if is_reparse_link(&p) {
            remove_link_only(&p)?;
        } else if entry.file_type().is_ok_and(|ft| ft.is_dir()) {
            remove_dir_tree_safely(&p)?;
        } else {
            fs::remove_file(&p)
                .map_err(|e| fail(format!("cannot remove file {}: {e}", p.display()), 1))?;
        }
    }
    fs::remove_dir(dir_path).map_err(|e| {
        fail(
            format!("cannot remove directory {}: {e}", dir_path.display()),
            1,
        )
    })
}

pub fn remove_empty_regular_dir(dir_path: &Path) {
    if dir_path.is_dir()
        && !is_reparse_link(dir_path)
        && fs::read_dir(dir_path)
            .map(|mut it| it.next().is_none())
            .unwrap_or(false)
    {
        let _ = fs::remove_dir(dir_path);
    }
}

pub fn test_path_within_root(root_dir: &Path, candidate_path: &Path) -> bool {
    let Ok(root_full) = normalize_path_str(&root_dir.to_string_lossy()) else {
        return false;
    };
    let Ok(cand_full) = normalize_path_str(&candidate_path.to_string_lossy()) else {
        return false;
    };
    if root_full.is_empty() || cand_full.is_empty() {
        return false;
    }
    let sep = std::path::MAIN_SEPARATOR;
    let root_prefix = if root_full.ends_with(sep) {
        root_full
    } else {
        format!("{root_full}{sep}")
    };
    if cfg!(windows) {
        cand_full.len() >= root_prefix.len()
            && cand_full[..root_prefix.len()].eq_ignore_ascii_case(&root_prefix)
    } else {
        cand_full.starts_with(&root_prefix)
    }
}

pub fn test_safe_header_path(val: &str) -> bool {
    if val.is_empty() || val != val.trim() || has_control_chars(val) {
        return false;
    }
    let b = val.as_bytes();
    for seg in val.split(['\\', '/']) {
        if seg == ".." {
            return false;
        }
    }
    val.starts_with('/')
        || (b.len() >= 3
            && b[0].is_ascii_alphabetic()
            && b[1] == b':'
            && matches!(b[2], b'\\' | b'/'))
}

pub fn test_safe_manifest_key(kind: &str, key: &str) -> bool {
    if key.is_empty()
        || key != key.trim()
        || key.starts_with('/')
        || key.ends_with('/')
        || key.starts_with('~')
        || key.contains('\\')
        || key.contains(':')
        || key.contains("//")
        || has_control_chars(key)
    {
        return false;
    }
    let segs: Vec<&str> = key.split('/').collect();
    if segs.iter().any(|s| s.is_empty() || *s == "." || *s == "..") {
        return false;
    }
    match kind {
        "skill" | "command" | "agent" => segs.len() == 1,
        "link" => segs.len() == 2 && segs[0] == "skills",
        "file" => {
            segs.len() == 1 || (segs.len() == 2 && (segs[0] == "rules" || segs[0] == "agents"))
        }
        _ => false,
    }
}

pub fn test_safe_manifest_value(kind: &str, val: &str) -> bool {
    if val.is_empty() || val != val.trim() || has_control_chars(val) {
        return false;
    }
    match kind {
        "command" | "agent" | "file" => {
            val.len() == 64 && val.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
        }
        "skill" | "link" => !val.contains('|') && test_safe_header_path(val),
        _ => false,
    }
}

#[derive(Debug, Clone)]
pub struct B3Manifest {
    pub exists: bool,
    pub corrupt: bool,
    pub schema: String,
    pub b3_home: String,
    pub plugin_root: String,
    pub sections: BTreeMap<String, BTreeMap<String, String>>,
}

impl B3Manifest {
    pub fn empty() -> Self {
        let mut sections = BTreeMap::new();
        for s in ["skill", "command", "agent", "file", "link"] {
            sections.insert(s.to_string(), BTreeMap::new());
        }
        Self {
            exists: false,
            corrupt: false,
            schema: String::new(),
            b3_home: String::new(),
            plugin_root: String::new(),
            sections,
        }
    }

    pub fn section(&self, name: &str) -> &BTreeMap<String, String> {
        &self.sections[name]
    }
}

pub fn read_b3_manifest(manifest_path: &Path) -> B3Manifest {
    let mut m = B3Manifest::empty();
    if !manifest_path.is_file() {
        return m;
    }
    m.exists = true;
    let Ok(raw_bytes) = fs::read(manifest_path) else {
        m.corrupt = true;
        return m;
    };
    let raw = String::from_utf8_lossy(&raw_bytes);
    let mut seen_schema = false;
    let mut seen_b3_home = false;
    let mut seen_plugin_root = false;

    for line in raw.split('\n') {
        let trimmed = line.trim_end_matches('\r');
        if trimmed.is_empty() {
            continue;
        }
        if let Some(hval) = trimmed.strip_prefix("schema=") {
            if seen_schema {
                m.corrupt = true;
                continue;
            }
            seen_schema = true;
            if hval.is_empty() || hval != hval.trim() || has_control_chars(hval) {
                m.corrupt = true;
                continue;
            }
            m.schema = hval.to_string();
            continue;
        }
        if let Some(hval) = trimmed.strip_prefix("b3_home=") {
            if seen_b3_home {
                m.corrupt = true;
                continue;
            }
            seen_b3_home = true;
            if !test_safe_header_path(hval) {
                m.corrupt = true;
                continue;
            }
            m.b3_home = hval.to_string();
            continue;
        }
        if let Some(hval) = trimmed.strip_prefix("plugin_root=") {
            if seen_plugin_root {
                m.corrupt = true;
                continue;
            }
            seen_plugin_root = true;
            if !test_safe_header_path(hval) {
                m.corrupt = true;
                continue;
            }
            m.plugin_root = hval.to_string();
            continue;
        }
        let parts: Vec<&str> = trimmed.splitn(3, '|').collect();
        if parts.len() != 3 {
            m.corrupt = true;
            continue;
        }
        let (kind, key, val) = (parts[0], parts[1], parts[2]);
        let Some(sec) = m.sections.get_mut(kind) else {
            m.corrupt = true;
            continue;
        };
        if !test_safe_manifest_key(kind, key)
            || sec.contains_key(key)
            || !test_safe_manifest_value(kind, val)
        {
            m.corrupt = true;
            continue;
        }
        sec.insert(key.to_string(), val.to_string());
    }
    m
}

pub fn write_b3_manifest(
    manifest_path: &Path,
    schema: &str,
    b3_home_forward: &str,
    plugin_root_forward: &str,
    entry_lines: &[String],
) -> Result<(), B3Error> {
    let mut lines = Vec::with_capacity(3 + entry_lines.len());
    lines.push(format!("schema={schema}"));
    lines.push(format!("b3_home={b3_home_forward}"));
    if !plugin_root_forward.is_empty() {
        lines.push(format!("plugin_root={plugin_root_forward}"));
    }
    for ln in entry_lines {
        if !ln.is_empty() {
            lines.push(ln.clone());
        }
    }
    write_utf8_no_bom_lf(manifest_path, &format!("{}\n", lines.join("\n")))
}

#[allow(clippy::too_many_arguments)]
pub fn uninstall_managed_link(
    root_dir: &Path,
    root_label: &str,
    path: &Path,
    expected_target: &str,
    verify_expected: bool,
    force: bool,
    dry_run: bool,
    unmanaged_label: &str,
    removed: &mut usize,
    skipped: &mut usize,
    out: &mut Vec<String>,
) -> Result<(), B3Error> {
    if !test_path_within_root(root_dir, path) {
        return Err(fail(
            format!(
                "refusing to uninstall path outside {root_label}: {}",
                path.display()
            ),
            1,
        ));
    }
    if is_reparse_link(path) {
        if verify_expected && !force {
            let exp_path = Path::new(expected_target);
            if expected_target.is_empty() || !test_link_target(path, exp_path, false) {
                eprintln!(
                    "WARNING: skipping retargeted skill link: {} (expected {expected_target}; re-run with -Force to remove)",
                    path.display()
                );
                *skipped += 1;
                return Ok(());
            }
        }
        if dry_run {
            out.push(format!("dry-run: remove skill link {}", path.display()));
        } else {
            remove_link_only(path)?;
        }
        *removed += 1;
    } else if path_exists_or_link(path) {
        eprintln!("WARNING: skipping {unmanaged_label}: {}", path.display());
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub fn uninstall_managed_file(
    root_dir: &Path,
    root_label: &str,
    path: &Path,
    expected_sha: &str,
    verify_sha: bool,
    marker_substr: &str,
    label: &str,
    sha_mismatch_label: &str,
    warned_containers: &mut Option<&mut std::collections::BTreeSet<String>>,
    force: bool,
    dry_run: bool,
    removed: &mut usize,
    skipped: &mut usize,
    out: &mut Vec<String>,
) -> Result<(), B3Error> {
    if !test_path_within_root(root_dir, path) {
        return Err(fail(
            format!(
                "refusing to uninstall path outside {root_label}: {}",
                path.display()
            ),
            1,
        ));
    }
    if let Some(warned) = warned_containers.as_deref_mut() {
        if let Some(parent_dir) = path.parent() {
            let p_norm = normalize_abs_path_str(parent_dir);
            let r_norm = normalize_abs_path_str(root_dir);
            let same = if cfg!(windows) {
                p_norm.eq_ignore_ascii_case(&r_norm)
            } else {
                p_norm == r_norm
            };
            if !same && is_reparse_link(parent_dir) {
                if warned.insert(p_norm) {
                    eprintln!(
                        "WARNING: skipping symlinked container directory: {}",
                        parent_dir.display()
                    );
                }
                *skipped += 1;
                return Ok(());
            }
        }
    }
    if is_reparse_link(path) {
        eprintln!("WARNING: skipping symlinked {label}: {}", path.display());
        *skipped += 1;
        return Ok(());
    }
    if !path.is_file() {
        return Ok(());
    }
    if !marker_substr.is_empty() {
        let txt = fs::read_to_string(path).unwrap_or_default();
        if !txt.contains(marker_substr) {
            eprintln!("WARNING: skipping unmanaged {label}: {}", path.display());
            return Ok(());
        }
    }
    if verify_sha && !force {
        let actual_sha = file_sha256(path).unwrap_or_default();
        if expected_sha.is_empty() || actual_sha != expected_sha {
            eprintln!(
                "WARNING: skipping {sha_mismatch_label}: {} (re-run with -Force to remove)",
                path.display()
            );
            *skipped += 1;
            return Ok(());
        }
    }
    if dry_run {
        out.push(format!("dry-run: remove {}", path.display()));
    } else {
        fs::remove_file(path)
            .map_err(|e| fail(format!("cannot remove {}: {e}", path.display()), 1))?;
    }
    *removed += 1;
    Ok(())
}
