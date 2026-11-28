use std::collections::BTreeSet;
use std::fs::{self, OpenOptions};
use std::io::{ErrorKind, Write};
use std::path::{Component, Path, PathBuf, Prefix};
use std::sync::atomic::{AtomicU64, Ordering};

use crate::error::{fail, B3Error};

static TMP_SEQ: AtomicU64 = AtomicU64::new(0);

/// Returns a monotonic unique suffix for temporary files created in this process.
pub fn next_tmp_suffix() -> String {
    let seq = TMP_SEQ.fetch_add(1, Ordering::Relaxed);
    format!("{}.{seq}", std::process::id())
}

/// Lexically resolves a path against `base` (collapsing `.` and `..` without
/// traversing symlinks/reparse points), matching PowerShell's
/// `GetUnresolvedProviderPathFromPSPath`.
pub fn resolve_unresolved_path(base: &Path, raw: &str) -> PathBuf {
    let trimmed = raw.trim();
    let candidate = if trimmed.is_empty() || trimmed == "." {
        base.to_path_buf()
    } else {
        let normalized = if cfg!(windows) {
            trimmed.replace('/', "\\")
        } else {
            trimmed.to_string()
        };
        let p = PathBuf::from(&normalized);
        if p.is_absolute() {
            p
        } else {
            base.join(p)
        }
    };
    lexical_normalize(&candidate)
}

fn lexical_normalize(path: &Path) -> PathBuf {
    let mut prefix_or_root: Option<PathBuf> = None;
    let mut stack: Vec<std::ffi::OsString> = Vec::new();
    let mut has_root = false;

    for comp in path.components() {
        match comp {
            Component::Prefix(p) => {
                prefix_or_root = Some(PathBuf::from(p.as_os_str()));
            }
            Component::RootDir => {
                has_root = true;
            }
            Component::CurDir => {}
            Component::ParentDir => {
                if !stack.is_empty() {
                    stack.pop();
                } else if !has_root && prefix_or_root.is_none() {
                    stack.push("..".into());
                }
            }
            Component::Normal(seg) => {
                stack.push(seg.to_os_string());
            }
        }
    }

    let mut out = prefix_or_root.unwrap_or_default();
    if has_root {
        out.push(std::path::MAIN_SEPARATOR_STR);
    }
    for seg in stack {
        out.push(seg);
    }
    if out.as_os_str().is_empty() {
        PathBuf::from(".")
    } else {
        out
    }
}

/// Resolves `--repo-root` relative to the current working directory.
pub fn normalize_repo_root(raw: &str) -> Result<PathBuf, B3Error> {
    let cwd = std::env::current_dir()
        .map_err(|e| fail(format!("REPO_ROOT_FAIL: unable to get cwd: {e}"), 1))?;
    Ok(resolve_unresolved_path(&cwd, raw))
}

/// Returns `true` if `path` exists as a symlink or Windows reparse point (junction/symlink).
pub fn is_reparse_or_symlink(path: &Path) -> bool {
    let meta = match fs::symlink_metadata(path) {
        Ok(m) => m,
        Err(e) if e.kind() == ErrorKind::NotFound => return false,
        Err(_) => return true, // fail closed on unreadable metadata
    };
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0400;
        meta.file_type().is_symlink()
            || (meta.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT) != 0
    }
    #[cfg(not(windows))]
    {
        meta.file_type().is_symlink()
    }
}

/// On Windows, returns `true` when `path` has a reparse point that is a non-symlink
/// mount point / NTFS Junction (`IO_REPARSE_TAG_MOUNT_POINT = 0xA0000003`).
#[cfg(windows)]
pub fn is_windows_junction(path: &Path) -> bool {
    use std::os::windows::ffi::OsStrExt;
    use std::os::windows::fs::MetadataExt;
    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0400;
    const IO_REPARSE_TAG_MOUNT_POINT: u32 = 0xA000_0003;

    let Ok(meta) = fs::symlink_metadata(path) else {
        return false;
    };
    if (meta.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT) == 0 {
        return false;
    }

    #[repr(C)]
    struct Win32FindDataW {
        dw_file_attributes: u32,
        ft_creation_time: [u32; 2],
        ft_last_access_time: [u32; 2],
        ft_last_write_time: [u32; 2],
        n_file_size_high: u32,
        n_file_size_low: u32,
        dw_reserved0: u32,
        dw_reserved1: u32,
        c_file_name: [u16; 260],
        c_alternate_file_name: [u16; 14],
    }

    extern "system" {
        fn FindFirstFileW(
            lp_file_name: *const u16,
            lp_find_file_data: *mut Win32FindDataW,
        ) -> isize;
        fn FindClose(h_find_file: isize) -> i32;
    }

    const INVALID_HANDLE_VALUE: isize = -1;
    let wide: Vec<u16> = path
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect();
    let mut data = Win32FindDataW {
        dw_file_attributes: 0,
        ft_creation_time: [0; 2],
        ft_last_access_time: [0; 2],
        ft_last_write_time: [0; 2],
        n_file_size_high: 0,
        n_file_size_low: 0,
        dw_reserved0: 0,
        dw_reserved1: 0,
        c_file_name: [0; 260],
        c_alternate_file_name: [0; 14],
    };
    // SAFETY: `wide` is NUL-terminated UTF-16 and `data` is zero-initialized on the stack.
    let handle = unsafe { FindFirstFileW(wide.as_ptr(), &mut data) };
    if handle == INVALID_HANDLE_VALUE {
        return false;
    }
    // SAFETY: `handle` is valid and non-INVALID_HANDLE_VALUE from `FindFirstFileW`.
    unsafe {
        FindClose(handle);
    }
    data.dw_reserved0 == IO_REPARSE_TAG_MOUNT_POINT
}

#[cfg(not(windows))]
pub fn is_windows_junction(_path: &Path) -> bool {
    false
}

/// Writes `text` with LF (`\n`) line endings atomically via a sibling temporary file.
/// Refuses to overwrite a directory or a symlink/reparse point.
pub fn write_atomic_lf(dest: &Path, text: &str) -> Result<(), B3Error> {
    if is_reparse_or_symlink(dest) {
        return Err(fail(
            format!(
                "WRITE_ERROR: refusing to write over directory or link: {}",
                dest.display()
            ),
            1,
        ));
    }
    if let Ok(meta) = fs::symlink_metadata(dest) {
        if meta.is_dir() {
            return Err(fail(
                format!(
                    "WRITE_ERROR: refusing to write over directory or link: {}",
                    dest.display()
                ),
                1,
            ));
        }
    }

    if let Some(parent) = dest.parent() {
        if !parent.as_os_str().is_empty() && !parent.exists() {
            fs::create_dir_all(parent).map_err(|e| {
                fail(
                    format!(
                        "WRITE_ERROR: failed to create parent directory {}: {e}",
                        parent.display()
                    ),
                    1,
                )
            })?;
        }
    }

    let lf_text = text.replace("\r\n", "\n").replace('\r', "\n");
    let file_name = dest
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or_else(|| fail("WRITE_ERROR: invalid destination file path", 1))?;
    let tmp_name = format!("{file_name}.tmp.{}", next_tmp_suffix());
    let tmp_path = dest.with_file_name(tmp_name);

    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&tmp_path)
        .map_err(|e| fail(format!("WRITE_ERROR: failed to create temp file: {e}"), 1))?;

    let write_res = file
        .write_all(lf_text.as_bytes())
        .and_then(|_| file.flush());
    drop(file);

    if let Err(e) = write_res {
        let _ = fs::remove_file(&tmp_path);
        return Err(fail(
            format!("WRITE_ERROR: failed writing temp file: {e}"),
            1,
        ));
    }

    if let Err(e) = fs::rename(&tmp_path, dest) {
        let _ = fs::remove_file(&tmp_path);
        return Err(fail(
            format!("WRITE_ERROR: failed to commit atomic write: {e}"),
            1,
        ));
    }

    Ok(())
}

/// Recursively deletes a directory tree without following symlinks or junctions.
pub fn remove_dir_tree_safely(target: &Path) -> Result<(), B3Error> {
    let meta = match fs::symlink_metadata(target) {
        Ok(m) => m,
        Err(e) if e.kind() == ErrorKind::NotFound => return Ok(()),
        Err(e) => {
            return Err(fail(
                format!(
                    "PRUNE_FAIL: unable to inspect path {}: {e}",
                    target.display()
                ),
                1,
            ))
        }
    };

    if is_reparse_or_symlink(target) {
        return Err(fail(
            format!(
                "PRUNE_FAIL: refusing recursive delete of link path: {}",
                target.display()
            ),
            1,
        ));
    }

    if !meta.is_dir() {
        fs::remove_file(target).map_err(|e| {
            fail(
                format!(
                    "PRUNE_FAIL: failed to remove file {}: {e}",
                    target.display()
                ),
                1,
            )
        })?;
        return Ok(());
    }

    let entries = fs::read_dir(target).map_err(|e| {
        fail(
            format!(
                "PRUNE_FAIL: failed to read directory {}: {e}",
                target.display()
            ),
            1,
        )
    })?;

    for entry_res in entries {
        let entry = entry_res.map_err(|e| {
            fail(
                format!(
                    "PRUNE_FAIL: failed reading entry in {}: {e}",
                    target.display()
                ),
                1,
            )
        })?;
        let child_path = entry.path();
        let child_meta = fs::symlink_metadata(&child_path).map_err(|e| {
            fail(
                format!(
                    "PRUNE_FAIL: failed inspecting {}: {e}",
                    child_path.display()
                ),
                1,
            )
        })?;

        if is_reparse_or_symlink(&child_path) {
            #[cfg(windows)]
            let is_dir_link = {
                use std::os::windows::fs::MetadataExt;
                const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x0010;
                (child_meta.file_attributes() & FILE_ATTRIBUTE_DIRECTORY) != 0
            };
            #[cfg(not(windows))]
            let is_dir_link = child_meta.is_dir();

            if is_dir_link {
                fs::remove_dir(&child_path).map_err(|e| {
                    fail(
                        format!(
                            "PRUNE_FAIL: failed removing link dir {}: {e}",
                            child_path.display()
                        ),
                        1,
                    )
                })?;
            } else {
                fs::remove_file(&child_path).map_err(|e| {
                    fail(
                        format!(
                            "PRUNE_FAIL: failed removing symlink {}: {e}",
                            child_path.display()
                        ),
                        1,
                    )
                })?;
            }
        } else if child_meta.is_dir() {
            remove_dir_tree_safely(&child_path)?;
        } else {
            fs::remove_file(&child_path).map_err(|e| {
                fail(
                    format!(
                        "PRUNE_FAIL: failed deleting file {}: {e}",
                        child_path.display()
                    ),
                    1,
                )
            })?;
        }
    }

    fs::remove_dir(target).map_err(|e| {
        fail(
            format!(
                "PRUNE_FAIL: failed deleting directory {}: {e}",
                target.display()
            ),
            1,
        )
    })
}

/// Normalizes a path string for pattern/scope comparisons (slash conversion,
/// strips leading `./`, trims trailing `/`).
pub fn normalize_path_value(path_value: &str) -> String {
    let mut norm = path_value.trim().replace('\\', "/");
    while let Some(stripped) = norm.strip_prefix("./") {
        norm = stripped.to_string();
    }
    norm.trim_end_matches('/').to_string()
}

/// Returns `true` if `s` contains any ASCII control character (`0x00..=0x1F` or `0x7F`).
pub fn has_control_chars(s: &str) -> bool {
    s.bytes().any(|b| b < 0x20 || b == 0x7F)
}

/// Splits a CSV list (optionally wrapped in `[...]`) into deduplicated items,
/// preserving first-seen order and skipping empty/`none` items.
pub fn split_csv_list(csv: &str) -> Vec<String> {
    let mut out = Vec::new();
    let trimmed = csv.trim();
    if trimmed.is_empty() || trimmed == "[]" || trimmed == "none" {
        return out;
    }
    let cleaned = if trimmed.starts_with('[') && trimmed.ends_with(']') && trimmed.len() >= 2 {
        &trimmed[1..trimmed.len() - 1]
    } else {
        trimmed
    };
    for part in cleaned.split(',') {
        let item = part.trim();
        if item.is_empty() || item == "none" {
            continue;
        }
        if !out.iter().any(|existing| existing == item) {
            out.push(item.to_string());
        }
    }
    out
}

/// Validates and parses a comma-separated list of repo-relative path prefixes,
/// matching `Split-PathCsvChecked` in `scripts/b3-guard.ps1`.
pub fn split_path_csv_checked(
    csv: &str,
    err_prefix: &str,
    reject_dot: bool,
    dot_message: Option<&str>,
) -> Result<Vec<String>, B3Error> {
    let mut list = Vec::new();
    if csv.is_empty() {
        return Ok(list);
    }
    if has_control_chars(csv) {
        return Err(fail(
            format!("{err_prefix}: invalid path control character"),
            1,
        ));
    }
    let trimmed = csv.trim();
    if trimmed.is_empty() || trimmed == "[]" || trimmed == "none" {
        return Ok(list);
    }
    let cleaned = if trimmed.starts_with('[') && trimmed.ends_with(']') && trimmed.len() >= 2 {
        &trimmed[1..trimmed.len() - 1]
    } else {
        trimmed
    };

    for part in cleaned.split(',') {
        let tok = part.trim();
        if tok.is_empty() || tok == "none" {
            continue;
        }
        if tok.contains('*') || tok.contains('?') {
            return Err(fail(
                format!("{err_prefix}: invalid glob in path '{tok}'"),
                1,
            ));
        }
        let slash = tok.replace('\\', "/");
        if slash.contains(':') || slash.starts_with('/') || has_dotdot_segment(&slash) {
            return Err(fail(format!("{err_prefix}: invalid path '{tok}'"), 1));
        }
        let item = if slash == "." || slash == "./" {
            ".".to_string()
        } else {
            normalize_path_value(tok)
        };
        if item.is_empty() {
            continue;
        }
        if reject_dot && item == "." {
            let msg = match dot_message {
                Some(m) if !m.is_empty() => m.to_string(),
                _ => format!("{err_prefix}: invalid ignore-dirty path '.'"),
            };
            return Err(fail(msg, 1));
        }
        if !list.iter().any(|existing| existing == &item) {
            list.push(item);
        }
    }

    Ok(list)
}

fn has_dotdot_segment(slash_path: &str) -> bool {
    slash_path.split('/').any(|seg| seg == "..")
}

/// Returns `true` if `path_val` belongs to B3's local checkpoint directories
/// (`.b3/ship`, `.b3/research-ship`, or `.b3/autodev`).
pub fn test_checkpoint_path(path_val: &str) -> bool {
    for prefix in [".b3/ship", ".b3/research-ship", ".b3/autodev"] {
        if path_val == prefix || path_val.starts_with(&format!("{prefix}/")) {
            return true;
        }
    }
    false
}

/// Prefix/exact match between a repo-relative `candidate` and pattern prefixes.
pub fn test_path_match(candidate: &str, patterns: &[String]) -> bool {
    if candidate.is_empty() {
        return false;
    }
    for p in patterns {
        if p == "." || candidate == p {
            return true;
        }
        if !p.is_empty()
            && candidate.len() > p.len()
            && candidate.starts_with(p.as_str())
            && candidate.as_bytes()[p.len()] == b'/'
        {
            return true;
        }
    }
    false
}

/// Sensitive path predicate matching `Test-SecretPath` in `scripts/b3-guard.ps1`.
pub fn test_secret_path(path_val: &str) -> bool {
    let leaf = path_val
        .rsplit('/')
        .next()
        .unwrap_or("")
        .to_ascii_lowercase();
    if leaf.is_empty() {
        return false;
    }
    if leaf == ".env" {
        return true;
    }
    if let Some(rest) = leaf.strip_prefix(".env.") {
        if matches!(rest, "example" | "sample" | "template") {
            return false;
        }
        return true;
    }
    if leaf.ends_with(".pem")
        || leaf.ends_with(".key")
        || leaf.ends_with(".p12")
        || leaf.ends_with(".pfx")
    {
        return true;
    }
    matches!(leaf.as_str(), "id_rsa" | "id_ed25519" | "credentials.json")
}

/// Deduplicates and ordinally sorts strings (ascending or descending).
pub fn sort_ordinal(items: impl IntoIterator<Item = String>, descending: bool) -> Vec<String> {
    let set: BTreeSet<String> = items.into_iter().collect();
    let mut vec: Vec<String> = set.into_iter().collect();
    if descending {
        vec.reverse();
    }
    vec
}

/// Splits a CSV list (optionally `[...]`) and normalizes each item as a slash path.
pub fn split_csv_list_as_paths(csv: &str) -> Vec<String> {
    let mut out = Vec::new();
    for item in split_csv_list(csv) {
        let norm = normalize_path_value(&item);
        if !norm.is_empty() && !out.iter().any(|existing| existing == &norm) {
            out.push(norm);
        }
    }
    out
}

/// Normalizes a path lexically matching `Normalize-LogicalPath` (`b3-guard.ps1`).
pub fn normalize_logical_path(raw: &str) -> Result<PathBuf, B3Error> {
    let cwd = std::env::current_dir()
        .map_err(|e| fail(format!("WORKTREE_FAIL: unable to get cwd: {e}"), 1))?;
    let logical_env = std::env::var("B3_LOGICAL_PWD")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .or_else(|| std::env::var("PWD").ok().filter(|s| !s.trim().is_empty()));
    let base = if let Some(lpwd) = logical_env {
        let lp = PathBuf::from(lpwd.trim());
        if lp.is_absolute()
            && !is_reparse_or_symlink(&cwd)
            && matches!(
                (fs::canonicalize(&lp), fs::canonicalize(&cwd)),
                (Ok(a), Ok(b)) if a == b
            )
        {
            lp
        } else {
            cwd
        }
    } else {
        cwd
    };
    Ok(resolve_unresolved_path(&base, raw))
}

/// Compares two path strings using filesystem case sensitivity.
pub fn paths_equal_fs(a: &str, b: &str, case_insensitive: bool) -> bool {
    if case_insensitive {
        a.eq_ignore_ascii_case(b)
    } else {
        a == b
    }
}

/// Returns `true` if `s` is a lowercase 64-character hex SHA-256 digest.
pub fn is_hex64_lower(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// Returns `true` if `ts` matches `YYYY-MM-DDTHH:MM:SSZ`.
pub fn valid_timestamp_utc(ts: &str) -> bool {
    let b = ts.as_bytes();
    b.len() == 20
        && b[0..4].iter().all(|c| c.is_ascii_digit())
        && b[4] == b'-'
        && b[5..7].iter().all(|c| c.is_ascii_digit())
        && b[7] == b'-'
        && b[8..10].iter().all(|c| c.is_ascii_digit())
        && b[10] == b'T'
        && b[11..13].iter().all(|c| c.is_ascii_digit())
        && b[13] == b':'
        && b[14..16].iter().all(|c| c.is_ascii_digit())
        && b[16] == b':'
        && b[17..19].iter().all(|c| c.is_ascii_digit())
        && b[19] == b'Z'
}

/// Returns `true` if `full` lies strictly inside `root`.
pub fn test_resolved_path_within_root(root: &Path, full: &Path) -> bool {
    let root_norm = normalize_path_value(&root.to_string_lossy());
    let full_norm = normalize_path_value(&full.to_string_lossy());
    if full_norm.is_empty() {
        return false;
    }
    if root_norm.is_empty() || root_norm == "/" {
        return full_norm.starts_with('/') && full_norm != "/";
    }
    if cfg!(windows) {
        let r_low = root_norm.to_ascii_lowercase();
        let f_low = full_norm.to_ascii_lowercase();
        f_low != r_low && f_low.starts_with(&format!("{r_low}/"))
    } else {
        full_norm != root_norm && full_norm.starts_with(&format!("{root_norm}/"))
    }
}

/// Checks every prefix segment of `rel_slash` under `root` to ensure none is a
/// symlink or reparse point (or unreadable).
pub fn test_no_reparse_segments(root: &Path, rel_slash: &str) -> bool {
    let mut cur = root.to_path_buf();
    for seg in rel_slash.split('/') {
        if seg.is_empty() || seg == "." {
            continue;
        }
        cur.push(seg);
        match fs::symlink_metadata(&cur) {
            Ok(meta) => {
                if is_reparse_or_symlink_meta(&meta) {
                    return false;
                }
            }
            Err(e) if e.kind() == ErrorKind::NotFound => {}
            Err(_) => return false,
        }
    }
    true
}

fn is_nonexempt_reparse(p: &Path) -> bool {
    #[cfg(target_os = "macos")]
    {
        if p == Path::new("/var") || p == Path::new("/tmp") {
            return false;
        }
    }
    is_reparse_or_symlink(p)
}

fn is_reparse_or_symlink_meta(meta: &fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        meta.file_type().is_symlink() || (meta.file_attributes() & 0x0400) != 0
    }
    #[cfg(not(windows))]
    {
        meta.file_type().is_symlink()
    }
}

/// Scans each component of an absolute path `abs_path` and returns the first
/// symlink/reparse segment if found.
pub fn find_reparse_in_path_hierarchy(abs_path: &Path) -> Option<PathBuf> {
    let mut cur = PathBuf::new();
    for comp in abs_path.components() {
        match comp {
            Component::Prefix(p) => cur.push(p.as_os_str()),
            Component::RootDir => cur.push(std::path::MAIN_SEPARATOR_STR),
            Component::CurDir => {}
            Component::ParentDir => {
                cur.pop();
            }
            Component::Normal(seg) => {
                cur.push(seg);
                if is_nonexempt_reparse(&cur) {
                    return Some(cur);
                }
            }
        }
    }
    None
}

/// Returns true if a string or path looks like a UNC, network, or Windows NT namespace path.
pub fn is_unc_or_network_path(raw: &str, p: &Path) -> bool {
    let raw_trimmed = raw.trim();
    let raw_bs = raw_trimmed.replace('/', "\\");
    if raw_bs.starts_with("\\\\") || raw_bs.to_ascii_uppercase().starts_with("\\??\\") {
        return true;
    }
    let s = p.to_string_lossy();
    let s_bs = s.replace('/', "\\");
    if s_bs.starts_with("\\\\") || s_bs.to_ascii_uppercase().starts_with("\\??\\") {
        return true;
    }
    p.components().any(|c| {
        matches!(
            c,
            Component::Prefix(pfx)
                if matches!(
                    pfx.kind(),
                    Prefix::UNC(..) | Prefix::VerbatimUNC(..) | Prefix::DeviceNS(..)
                )
        )
    })
}

/// Returns true if `path` or any traversed step (including uncollapsed `sym/..` prefixes and
/// resolved ancestors above `base`) is a non-exempt symlink or reparse point.
pub fn has_reparse_in_path_steps(base: &Path, path: &Path) -> bool {
    if is_nonexempt_reparse(path) {
        return true;
    }
    let s = path.to_string_lossy();
    let s_norm = if cfg!(windows) {
        s.replace('/', "\\")
    } else {
        s.into_owned()
    };
    let p_norm = PathBuf::from(&s_norm);
    let joined = if p_norm.is_absolute() {
        p_norm
    } else {
        base.join(&p_norm)
    };
    let mut cur = PathBuf::new();
    for comp in joined.components() {
        match comp {
            Component::Prefix(_) | Component::RootDir | Component::Normal(_) => {
                cur.push(comp.as_os_str());
                if is_nonexempt_reparse(&cur) {
                    return true;
                }
            }
            Component::ParentDir => {
                if !cur.as_os_str().is_empty() && is_nonexempt_reparse(&cur) {
                    return true;
                }
                cur.push("..");
                if is_nonexempt_reparse(&cur) {
                    return true;
                }
            }
            Component::CurDir => {}
        }
    }
    let resolved = resolve_unresolved_path(base, &s_norm);
    is_nonexempt_reparse(&resolved) || find_reparse_in_path_hierarchy(&resolved).is_some()
}

/// Validates repo-relative segments (optional `.git` blocking), matching
/// `Test-SafeRepoPathSegments`.
pub fn test_safe_repo_path_segments(path_val: &str, block_git: bool) -> bool {
    if path_val.is_empty() || has_control_chars(path_val) {
        return false;
    }
    let s = path_val.replace('\\', "/");
    if s.contains(':')
        || s.starts_with('/')
        || s.ends_with('/')
        || s.starts_with('~')
        || s.contains('*')
        || s.contains('?')
    {
        return false;
    }
    for seg in s.split('/') {
        if seg.is_empty() || seg == "." || seg == ".." || seg.ends_with('.') || seg.ends_with(' ') {
            return false;
        }
    }
    !(block_git && s.split('/').any(|seg| seg.eq_ignore_ascii_case(".git")))
}

/// Computes repo-relative slash path from `root` and `full`.
pub fn get_repo_relative_path(root: &Path, full: &Path) -> String {
    let root_norm = normalize_path_value(&root.to_string_lossy());
    let full_norm = normalize_path_value(&full.to_string_lossy());
    if root_norm == "." {
        return full_norm;
    }
    let r_low = root_norm.to_ascii_lowercase();
    let f_low = full_norm.to_ascii_lowercase();
    if f_low.starts_with(&format!("{r_low}/")) {
        return full_norm[root_norm.len() + 1..].to_string();
    }
    if f_low == r_low {
        return ".".to_string();
    }
    full_norm
}

pub(crate) fn expand_windows_long_existing_prefix(path: &Path) -> PathBuf {
    #[cfg(windows)]
    {
        if path.exists() {
            return expand_windows_long_path(path);
        }
        let mut tail: Vec<std::ffi::OsString> = Vec::new();
        let mut cur = path;
        while let (Some(name), Some(parent)) = (cur.file_name(), cur.parent()) {
            tail.push(name.to_os_string());
            if parent.exists() {
                let mut out = expand_windows_long_path(parent);
                for seg in tail.into_iter().rev() {
                    out.push(seg);
                }
                return out;
            }
            cur = parent;
        }
        path.to_path_buf()
    }
    #[cfg(not(windows))]
    {
        path.to_path_buf()
    }
}

/// Validates and resolves a safe repo-contained write path (`FullPath`, `RelPath`),
/// matching `Resolve-SafeRepoWritePath`.
pub fn resolve_safe_repo_write_path(root: &Path, path_arg: &str) -> Option<(PathBuf, String)> {
    if path_arg.trim().is_empty() || has_control_chars(path_arg) || path_arg.ends_with(' ') {
        return None;
    }
    let trimmed = path_arg.trim();
    let slash_arg = trimmed.replace('\\', "/");
    if slash_arg.is_empty()
        || slash_arg == "."
        || slash_arg.starts_with('~')
        || slash_arg.ends_with('/')
    {
        return None;
    }
    let raw_tail = if cfg!(windows)
        && slash_arg.len() >= 3
        && slash_arg.as_bytes()[0].is_ascii_alphabetic()
        && &slash_arg.as_bytes()[1..3] == b":/"
    {
        &slash_arg[3..]
    } else if let Some(rest) = slash_arg.strip_prefix('/') {
        rest
    } else {
        slash_arg.as_str()
    };
    if !test_safe_repo_path_segments(raw_tail, false) {
        return None;
    }

    let root_eff = expand_windows_long_existing_prefix(root);
    let full = expand_windows_long_existing_prefix(&resolve_unresolved_path(&root_eff, trimmed));
    if !test_resolved_path_within_root(&root_eff, &full) {
        return None;
    }
    let rel = get_repo_relative_path(&root_eff, &full);
    if rel.is_empty() || Path::new(&rel).is_absolute() || !test_safe_repo_path_segments(&rel, true)
    {
        return None;
    }
    if !test_no_reparse_segments(&root_eff, &rel) {
        return None;
    }
    Some((full, rel))
}

/// Validates a repo-relative path strictly contained in `root` (blocks wildcards,
/// brackets, `.git`, reparse segments), matching `Test-ContainedRepoPath`.
pub fn test_contained_repo_path(root: &Path, path_arg: &str) -> Option<(PathBuf, String)> {
    if path_arg.is_empty()
        || has_control_chars(path_arg)
        || path_arg.trim().is_empty()
        || path_arg.ends_with(' ')
    {
        return None;
    }
    let trimmed = path_arg.trim();
    if trimmed.contains(':') {
        return None;
    }
    let raw_slash = trimmed.replace('\\', "/");
    if raw_slash.is_empty() || raw_slash.ends_with('/') {
        return None;
    }
    let p = normalize_path_value(trimmed);
    if p.is_empty()
        || p == "."
        || p.starts_with('/')
        || p.starts_with('~')
        || p.contains(':')
        || has_dotdot_segment(&p)
        || p.contains('*')
        || p.contains('?')
        || p.contains('[')
    {
        return None;
    }
    for seg in p.split('/') {
        if seg.is_empty() || seg.ends_with('.') || seg.ends_with(' ') {
            return None;
        }
    }
    if p.split('/').any(|seg| seg.eq_ignore_ascii_case(".git")) {
        return None;
    }
    let full = resolve_unresolved_path(root, &p);
    if !test_resolved_path_within_root(root, &full) {
        return None;
    }
    if !test_no_reparse_segments(root, &p) {
        return None;
    }
    Some((full, p))
}

/// Returns `true` if `root_a` and `root_b` are identical or nested inside one another.
pub fn test_worktree_root_overlap(root_a: &str, root_b: &str, case_insensitive: bool) -> bool {
    let a = if case_insensitive {
        root_a.to_ascii_lowercase()
    } else {
        root_a.to_string()
    };
    let b = if case_insensitive {
        root_b.to_ascii_lowercase()
    } else {
        root_b.to_string()
    };
    if a == b {
        return true;
    }
    let a_base = a.trim_end_matches('/');
    let b_base = b.trim_end_matches('/');
    if a_base.is_empty() || b_base.is_empty() {
        return false;
    }
    a.starts_with(&format!("{b_base}/")) || b.starts_with(&format!("{a_base}/"))
}

/// Noise file predicate matching `Test-NoiseFile` (`b3-guard.ps1`).
pub fn test_noise_file(path_val: &str) -> bool {
    let leaf = path_val.rsplit('/').next().unwrap_or("");
    if matches!(
        leaf,
        "package-lock.json"
            | "pnpm-lock.yaml"
            | "yarn.lock"
            | "bun.lockb"
            | "packages.lock.json"
            | "Cargo.lock"
            | "poetry.lock"
    ) {
        return true;
    }
    let lower = leaf.to_ascii_lowercase();
    lower.ends_with(".min.js")
        || lower.ends_with(".min.css")
        || lower.ends_with(".snap")
        || lower.ends_with(".designer.cs")
        || lower.ends_with(".g.cs")
        || lower.ends_with(".map")
}

/// Test file path predicate matching `Test-TestPath` (`b3-guard.ps1`).
pub fn test_test_path(path_val: &str) -> bool {
    let lower = path_val.to_ascii_lowercase();
    if lower
        .split('/')
        .any(|seg| matches!(seg, "test" | "tests" | "__tests__"))
    {
        return true;
    }
    lower.contains(".test.") || lower.contains(".spec.")
}

/// Source code file extension predicate matching `Test-CodePath` (`b3-guard.ps1`).
pub fn test_code_path(path_val: &str) -> bool {
    matches!(
        Path::new(path_val).extension().and_then(|e| e.to_str()),
        Some(
            "js" | "jsx"
                | "ts"
                | "tsx"
                | "mjs"
                | "cjs"
                | "py"
                | "go"
                | "cs"
                | "java"
                | "rs"
                | "ps1"
                | "sh"
        )
    )
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WaveOverlap {
    None,
    Equal,
    Prefix,
}

/// Computes overlap kind between two normalized wave paths.
pub fn test_wave_path_overlap(path_a: &str, path_b: &str, case_insensitive: bool) -> WaveOverlap {
    let (a, b) = if case_insensitive {
        (path_a.to_ascii_lowercase(), path_b.to_ascii_lowercase())
    } else {
        (path_a.to_string(), path_b.to_string())
    };
    if a == b {
        return WaveOverlap::Equal;
    }
    if a == "." || b == "." || a.starts_with(&format!("{b}/")) || b.starts_with(&format!("{a}/")) {
        return WaveOverlap::Prefix;
    }
    WaveOverlap::None
}

/// Validates that `norm_path` under `root` is strictly contained and has no
/// symlink/reparse segments or descendants (skipping `.git`).
pub fn test_wave_path_contained(root: &Path, norm_path: &str) -> bool {
    if !root.is_dir() || norm_path.is_empty() || norm_path == "." {
        return true;
    }
    let full = resolve_unresolved_path(root, norm_path);
    if !test_resolved_path_within_root(root, &full) {
        return false;
    }
    if !test_no_reparse_segments(root, norm_path) {
        return false;
    }
    if full.is_dir() {
        let mut stack = vec![full];
        while let Some(dir_cur) = stack.pop() {
            let Ok(entries) = fs::read_dir(&dir_cur) else {
                continue;
            };
            for entry in entries.flatten() {
                let name = entry.file_name();
                if name.to_string_lossy().eq_ignore_ascii_case(".git") {
                    continue;
                }
                let child = entry.path();
                if is_reparse_or_symlink(&child) {
                    return false;
                }
                if let Ok(meta) = fs::symlink_metadata(&child) {
                    if meta.is_dir() {
                        stack.push(child);
                    }
                }
            }
        }
    }
    true
}

#[derive(Debug, Clone)]
pub struct ParsedWavePaths {
    pub paths: Vec<String>,
    pub explicit_empty: bool,
}

pub fn is_protected_wave_path(norm: &str) -> bool {
    let low = norm.to_ascii_lowercase();
    if low == ".b3" || low.starts_with(".b3/") {
        return true;
    }
    if low.split('/').any(|seg| seg == ".git") {
        return true;
    }
    low == ".gitmodules" || low.ends_with("/.gitmodules")
}

/// Parses and validates a CSV list of wave paths matching `ConvertTo-WavePaths`.
pub fn convert_to_wave_paths(
    csv: &str,
    reject_protected: bool,
    reject_dot: bool,
    err_prefix: &str,
) -> Result<ParsedWavePaths, B3Error> {
    if csv.is_empty() {
        return Ok(ParsedWavePaths {
            paths: Vec::new(),
            explicit_empty: false,
        });
    }
    let mut cleaned = csv.trim();
    if cleaned == "[]" || cleaned == "none" {
        return Ok(ParsedWavePaths {
            paths: Vec::new(),
            explicit_empty: true,
        });
    }
    if cleaned.starts_with('[') && cleaned.ends_with(']') && cleaned.len() >= 2 {
        cleaned = &cleaned[1..cleaned.len() - 1];
    }

    let mut list = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for part in cleaned.split(',') {
        if has_control_chars(part) {
            let trimmed = part.trim();
            let disp = if trimmed.is_empty() { part } else { trimmed };
            return Err(fail(format!("{err_prefix}: invalid path '{disp}'"), 1));
        }
        let tok = part.trim();
        if tok.is_empty() || tok == "none" {
            continue;
        }
        let slash = tok.replace('\\', "/");
        if slash.contains('|')
            || slash.contains(':')
            || slash.starts_with('/')
            || slash.contains("//")
            || has_dotdot_segment(&slash)
            || slash.contains('*')
            || slash.contains('?')
        {
            return Err(fail(format!("{err_prefix}: invalid path '{tok}'"), 1));
        }

        let norm = if slash == "." || slash == "./" {
            ".".to_string()
        } else {
            if slash.contains("/./") || slash.ends_with("/.") {
                return Err(fail(format!("{err_prefix}: invalid path '{tok}'"), 1));
            }
            let stripped = slash.strip_prefix("./").unwrap_or(&slash);
            let trimmed = stripped.trim_end_matches('/').to_string();
            if trimmed.is_empty() || trimmed == "." || trimmed == ".." {
                return Err(fail(format!("{err_prefix}: invalid path '{tok}'"), 1));
            }
            for seg in trimmed.split('/') {
                if seg.is_empty()
                    || seg == "."
                    || seg == ".."
                    || seg.ends_with('.')
                    || seg.ends_with(' ')
                {
                    return Err(fail(format!("{err_prefix}: invalid path '{tok}'"), 1));
                }
            }
            trimmed
        };

        if reject_protected && is_protected_wave_path(&norm) {
            return Err(fail(
                format!("{err_prefix}: protected path '{norm}' cannot be worker-owned"),
                1,
            ));
        }
        if reject_dot && norm == "." {
            return Err(fail(
                format!(
                    "{err_prefix}: protected path '.' cannot be worker-owned in parallel partition"
                ),
                1,
            ));
        }
        if seen.insert(norm.clone()) {
            list.push(norm);
        }
    }

    Ok(ParsedWavePaths {
        paths: list,
        explicit_empty: false,
    })
}

pub struct ParsedWaveTaskMap {
    pub order: Vec<String>,
    pub map: std::collections::HashMap<String, Vec<String>>,
    pub total_paths: usize,
}

pub fn is_valid_task_id(tid: &str) -> bool {
    !tid.is_empty()
        && tid
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
}

/// Parses `TaskId=path1,path2;...` specs matching `ConvertTo-WaveTaskMap`.
#[allow(clippy::too_many_arguments)]
pub fn convert_to_wave_task_map(
    specs: &str,
    root: &Path,
    err_prefix: &str,
    spec_label: &str,
    empty_arg_label: &str,
    reject_protected: bool,
    reject_dot: bool,
    allow_empty: bool,
    allowed_task_ids: Option<&std::collections::HashSet<String>>,
) -> Result<ParsedWaveTaskMap, B3Error> {
    let mut order = Vec::new();
    let mut map = std::collections::HashMap::new();
    let mut total_paths = 0usize;
    let repo_exists = root.is_dir();
    let entry_label = if spec_label == "WaveSpecs" {
        "entry".to_string()
    } else {
        format!("{spec_label} entry")
    };

    for entry in specs.split(';') {
        let trim_entry = entry.trim();
        if trim_entry.is_empty() {
            continue;
        }
        let Some(eq_idx) = trim_entry.find('=') else {
            return Err(fail(
                format!("{err_prefix}: invalid {entry_label} '{trim_entry}' (expected TaskId=path1,path2)"),
                1,
            ));
        };
        let tid = trim_entry[..eq_idx].trim().to_string();
        let raw_csv = &trim_entry[eq_idx + 1..];
        if tid.is_empty() {
            return Err(fail(
                format!("{err_prefix}: empty task id in '{trim_entry}'"),
                1,
            ));
        }
        if !is_valid_task_id(&tid) {
            return Err(fail(format!("{err_prefix}: invalid task id '{tid}'"), 1));
        }
        if map.contains_key(&tid) {
            let dup_suffix = if spec_label == "WaveSpecs" {
                String::new()
            } else {
                format!(" in {spec_label}")
            };
            return Err(fail(
                format!("{err_prefix}: duplicate task id '{tid}'{dup_suffix}"),
                1,
            ));
        }
        if let Some(allowed) = allowed_task_ids {
            if !allowed.contains(&tid) {
                return Err(fail(
                    format!("{err_prefix}: unknown task id '{tid}' in {spec_label}"),
                    1,
                ));
            }
        }
        let parsed = convert_to_wave_paths(raw_csv, reject_protected, reject_dot, err_prefix)?;
        if parsed.paths.is_empty() && !(allow_empty && parsed.explicit_empty) {
            return Err(fail(
                format!("{err_prefix}: task '{tid}' has no owned paths"),
                1,
            ));
        }
        if repo_exists {
            for wp in &parsed.paths {
                if !test_wave_path_contained(root, wp) {
                    return Err(fail(
                        format!("{err_prefix}: unsafe symlink or junction alias in path '{wp}'"),
                        1,
                    ));
                }
            }
        }
        total_paths += parsed.paths.len();
        order.push(tid.clone());
        map.insert(tid, parsed.paths);
    }

    if order.is_empty() {
        return Err(fail(
            format!("{err_prefix}: no tasks in {empty_arg_label}"),
            1,
        ));
    }

    Ok(ParsedWaveTaskMap {
        order,
        map,
        total_paths,
    })
}

/// Returns `true` if the first 8 KiB of `full_path` contains a NUL byte (`0x00`).
pub fn test_binary_file(full_path: &Path) -> bool {
    if !full_path.is_file() {
        return false;
    }
    use std::io::Read;
    let Ok(mut file) = fs::File::open(full_path) else {
        return false;
    };
    let mut buf = [0u8; 8192];
    let Ok(n) = file.read(&mut buf) else {
        return false;
    };
    buf[..n].contains(&0)
}

/// Case-sensitive or case-insensitive prefix/exact ownership matching,
/// matching `Test-OwnershipPathMatch`.
pub fn test_ownership_path_match(
    candidate: &str,
    patterns: &[String],
    case_insensitive: bool,
) -> bool {
    if candidate.is_empty() || patterns.is_empty() {
        return false;
    }
    let cand_cmp = if case_insensitive {
        candidate.to_ascii_lowercase()
    } else {
        candidate.to_string()
    };
    for p in patterns {
        if p == "." {
            return true;
        }
        let p_cmp = if case_insensitive {
            p.to_ascii_lowercase()
        } else {
            p.clone()
        };
        if cand_cmp == p_cmp {
            return true;
        }
        if !p_cmp.is_empty()
            && cand_cmp.len() > p_cmp.len()
            && cand_cmp.starts_with(&p_cmp)
            && cand_cmp.as_bytes()[p_cmp.len()] == b'/'
        {
            return true;
        }
    }
    false
}

/// Computes lowercase hex SHA-256 digest of a file (FIPS 180-4, pure `std`).
pub fn sha256_file_hex(path: &Path) -> Result<String, B3Error> {
    let bytes = fs::read(path).map_err(|e| {
        fail(
            format!(
                "MECHANICAL_FAIL: failed reading {} for sha256: {e}",
                path.display()
            ),
            1,
        )
    })?;
    Ok(sha256_bytes_hex(&bytes))
}

pub fn sha256_bytes_hex(data: &[u8]) -> String {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
        0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
        0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
        0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
        0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
        0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ];
    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];

    let bit_len = (data.len() as u64) * 8;
    let mut padded = Vec::with_capacity((data.len() + 9).div_ceil(64) * 64);
    padded.extend_from_slice(data);
    padded.push(0x80);
    while (padded.len() % 64) != 56 {
        padded.push(0);
    }
    padded.extend_from_slice(&bit_len.to_be_bytes());

    for block in padded.chunks_exact(64) {
        let mut w = [0u32; 64];
        for (i, chunk) in block.chunks_exact(4).enumerate() {
            w[i] = u32::from_be_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }
        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut hh] = h;
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ ((!e) & g);
            let temp1 = hh
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(K[i])
                .wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let temp2 = s0.wrapping_add(maj);

            hh = g;
            g = f;
            f = e;
            e = d.wrapping_add(temp1);
            d = c;
            c = b;
            b = a;
            a = temp1.wrapping_add(temp2);
        }
        for (acc, val) in h.iter_mut().zip([a, b, c, d, e, f, g, hh]) {
            *acc = acc.wrapping_add(val);
        }
    }

    let mut hex = String::with_capacity(64);
    for word in h {
        hex.push_str(&format!("{word:08x}"));
    }
    hex
}

/// Computes lowercase hex SHA-1 digest of `data` (FIPS 180-4, pure `std`).
pub fn sha1_bytes_hex(data: &[u8]) -> String {
    let mut h: [u32; 5] = [
        0x6745_2301,
        0xEFCD_AB89,
        0x98BA_DCFE,
        0x1032_5476,
        0xC3D2_E1F0,
    ];
    let bit_len = (data.len() as u64) * 8;
    let mut padded = Vec::with_capacity((data.len() + 9).div_ceil(64) * 64);
    padded.extend_from_slice(data);
    padded.push(0x80);
    while (padded.len() % 64) != 56 {
        padded.push(0);
    }
    padded.extend_from_slice(&bit_len.to_be_bytes());

    for block in padded.chunks_exact(64) {
        let mut w = [0u32; 80];
        for (i, chunk) in block.chunks_exact(4).enumerate() {
            w[i] = u32::from_be_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
        }
        for i in 16..80 {
            w[i] = (w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]).rotate_left(1);
        }
        let [mut a, mut b, mut c, mut d, mut e] = h;
        for (i, &wi) in w.iter().enumerate() {
            let (f, k) = match i {
                0..=19 => ((b & c) | ((!b) & d), 0x5A82_7999u32),
                20..=39 => (b ^ c ^ d, 0x6ED9_EBA1u32),
                40..=59 => ((b & c) | (b & d) | (c & d), 0x8F1B_BCDCu32),
                _ => (b ^ c ^ d, 0xCA62_C1D6u32),
            };
            let temp = a
                .rotate_left(5)
                .wrapping_add(f)
                .wrapping_add(e)
                .wrapping_add(k)
                .wrapping_add(wi);
            e = d;
            d = c;
            c = b.rotate_left(30);
            b = a;
            a = temp;
        }
        for (acc, val) in h.iter_mut().zip([a, b, c, d, e]) {
            *acc = acc.wrapping_add(val);
        }
    }

    let mut hex = String::with_capacity(40);
    for word in h {
        hex.push_str(&format!("{word:08x}"));
    }
    hex
}

/// Expands existing Windows 8.3 short path segments (e.g. `RUNNER~1`) to their
/// long names via `GetLongPathNameW` without resolving symlinks or NTFS junctions.
#[cfg(windows)]
pub fn expand_windows_long_path(path: &Path) -> PathBuf {
    use std::ffi::OsString;
    use std::os::windows::ffi::{OsStrExt, OsStringExt};

    extern "system" {
        fn GetLongPathNameW(
            lpsz_short_path: *const u16,
            lpsz_long_path: *mut u16,
            cch_buffer: u32,
        ) -> u32;
    }

    let wide: Vec<u16> = path
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect();
    // SAFETY: `wide` is NUL-terminated UTF-16; null buffer with size 0 queries the required length.
    let needed = unsafe { GetLongPathNameW(wide.as_ptr(), std::ptr::null_mut(), 0) };
    if needed == 0 {
        return path.to_path_buf();
    }
    let mut buf = vec![0u16; needed as usize];
    // SAFETY: `wide` is NUL-terminated UTF-16 and `buf` is allocated with `needed` u16 elements.
    let written = unsafe { GetLongPathNameW(wide.as_ptr(), buf.as_mut_ptr(), needed) };
    if written == 0 || written >= needed {
        return path.to_path_buf();
    }
    PathBuf::from(OsString::from_wide(&buf[..written as usize]))
}

/// Non-Windows no-op counterpart of `expand_windows_long_path`.
#[cfg(not(windows))]
pub fn expand_windows_long_path(path: &Path) -> PathBuf {
    path.to_path_buf()
}

#[cfg(all(test, windows))]
pub(crate) fn to_short_path(path: &Path) -> Option<PathBuf> {
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
    // SAFETY: `wide` is NUL-terminated UTF-16; null buffer queries required length.
    let needed = unsafe { GetShortPathNameW(wide.as_ptr(), std::ptr::null_mut(), 0) };
    if needed == 0 {
        return None;
    }
    let mut buf = vec![0u16; needed as usize];
    // SAFETY: `wide` is NUL-terminated UTF-16 and `buf` has `needed` elements.
    let written = unsafe { GetShortPathNameW(wide.as_ptr(), buf.as_mut_ptr(), needed) };
    if written == 0 || written >= needed {
        return None;
    }
    Some(PathBuf::from(OsString::from_wide(&buf[..written as usize])))
}

#[cfg(all(test, windows))]
pub(crate) fn remove_link_only(link_path: &Path) {
    let Ok(meta) = fs::symlink_metadata(link_path) else {
        return;
    };
    use std::os::windows::fs::MetadataExt;
    const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;
    if (meta.file_attributes() & FILE_ATTRIBUTE_DIRECTORY) != 0 {
        let _ = fs::remove_dir(link_path);
    } else {
        let _ = fs::remove_file(link_path);
    }
}

#[cfg(all(test, windows))]
mod tests {
    use super::{expand_windows_long_path, remove_link_only, to_short_path};
    use std::fs;
    use std::process::Command;

    #[test]
    fn expand_windows_long_path_expands_83_and_preserves_junctions() {
        let root = std::env::temp_dir().join(format!("b3-fs-longpath-{}", std::process::id()));
        if root.exists() {
            let _ = fs::remove_dir_all(&root);
        }
        let long_dir = root.join("long_directory_name_test");
        let target_dir = root.join("junction_target_dir");
        let junction_dir = root.join("junction_link");
        fs::create_dir_all(&long_dir).expect("create long dir");
        fs::create_dir_all(&target_dir).expect("create target dir");

        let mklink = Command::new("cmd")
            .args([
                "/d",
                "/c",
                "mklink",
                "/J",
                &junction_dir.to_string_lossy(),
                &target_dir.to_string_lossy(),
            ])
            .output()
            .expect("run mklink /J");
        assert!(mklink.status.success(), "mklink /J failed");

        let junc_expanded = expand_windows_long_path(&junction_dir);
        assert_eq!(
            junc_expanded.file_name().and_then(|n| n.to_str()),
            Some("junction_link"),
            "GetLongPathNameW must not dereference NTFS junctions: {junc_expanded:?}"
        );

        let expected_long = expand_windows_long_path(&long_dir);
        assert_eq!(
            expected_long.file_name().and_then(|n| n.to_str()),
            Some("long_directory_name_test")
        );
        if let Some(short_path) = to_short_path(&long_dir) {
            let from_short = expand_windows_long_path(&short_path);
            assert_eq!(
                from_short.to_string_lossy().to_ascii_lowercase(),
                expected_long.to_string_lossy().to_ascii_lowercase()
            );
            assert_eq!(
                from_short.file_name().and_then(|n| n.to_str()),
                Some("long_directory_name_test")
            );
        }

        remove_link_only(&junction_dir);
        let _ = fs::remove_dir_all(&root);
    }
}

#[cfg(all(test, unix))]
mod unix_tests {
    use super::{find_reparse_in_path_hierarchy, normalize_logical_path};
    use std::fs;

    struct EnvRestore {
        key: &'static str,
        prev: Option<std::ffi::OsString>,
    }

    impl Drop for EnvRestore {
        fn drop(&mut self) {
            match &self.prev {
                Some(v) => std::env::set_var(self.key, v),
                None => std::env::remove_var(self.key),
            }
        }
    }

    #[test]
    fn normalize_logical_path_detects_pwd_symlink_without_b3_logical_pwd() {
        let cwd = std::env::current_dir().expect("cwd");
        let root = std::env::temp_dir().join(format!("b3-fs-pwd-sym-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).expect("create temp dir");
        let sym_cwd = root.join("sym_cwd");
        std::os::unix::fs::symlink(&cwd, &sym_cwd).expect("create symlink");

        let _g_b3 = EnvRestore {
            key: "B3_LOGICAL_PWD",
            prev: std::env::var_os("B3_LOGICAL_PWD"),
        };
        let _g_pwd = EnvRestore {
            key: "PWD",
            prev: std::env::var_os("PWD"),
        };
        std::env::remove_var("B3_LOGICAL_PWD");
        std::env::set_var("PWD", &sym_cwd);

        let resolved = normalize_logical_path(".").expect("normalize_logical_path");
        assert_eq!(resolved, sym_cwd);
        assert!(
            find_reparse_in_path_hierarchy(&resolved).is_some(),
            "expected symlinked PWD {resolved:?} to trigger reparse hierarchy detection"
        );

        let _ = fs::remove_dir_all(&root);
    }
}
