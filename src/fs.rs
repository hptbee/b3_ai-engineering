use std::collections::BTreeSet;
use std::fs::{self, OpenOptions};
use std::io::{ErrorKind, Write};
use std::path::{Component, Path, PathBuf};
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
    if meta.file_type().is_symlink() {
        return true;
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0400;
        if (meta.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT) != 0 {
            return true;
        }
    }
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
            if child_meta.is_dir() {
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
