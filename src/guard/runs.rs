use std::fs;
use std::path::{Path, PathBuf};

use crate::error::{fail, B3Error};
use crate::fs::{
    is_reparse_or_symlink, normalize_repo_root, remove_dir_tree_safely, sort_ordinal,
    write_atomic_lf,
};

fn resolve_namespace_dir(root: &Path, ns: &str) -> Result<(String, PathBuf), B3Error> {
    let trimmed = if ns.trim().is_empty() {
        "ship"
    } else {
        ns.trim()
    };
    match trimmed {
        "ship" => Ok(("ship".to_string(), root.join(".b3").join("ship"))),
        "research-ship" => Ok((
            "research-ship".to_string(),
            root.join(".b3").join("research-ship"),
        )),
        _ => Err(fail(format!("INVALID_NAMESPACE: {trimmed}"), 1)),
    }
}

fn assert_runs_dirs_not_links(
    root: &Path,
    ns_dir: &Path,
    runs_dir: &Path,
    err_prefix: &str,
) -> Result<(), B3Error> {
    let dot_b3 = root.join(".b3");
    if is_reparse_or_symlink(&dot_b3)
        || is_reparse_or_symlink(ns_dir)
        || is_reparse_or_symlink(runs_dir)
    {
        return Err(fail(format!("{err_prefix}: runs directory is a link"), 1));
    }
    Ok(())
}

fn sanitized_slug(raw_slug: &str) -> String {
    let mut out = String::new();
    let mut prev_dash = true; // suppresses leading '-'
    for ch in raw_slug.chars() {
        let lower = ch.to_ascii_lowercase();
        if lower.is_ascii_alphanumeric() {
            out.push(lower);
            prev_dash = false;
        } else if !prev_dash {
            out.push('-');
            prev_dash = true;
        }
    }
    let trimmed = out.trim_matches('-');
    let truncated = if trimmed.len() > 40 {
        &trimmed[..40]
    } else {
        trimmed
    };
    truncated.trim_matches('-').to_string()
}

fn valid_run_id(id: &str) -> bool {
    if id.is_empty() || id.contains("..") || id.contains('/') || id.contains('\\') {
        return false;
    }
    let mut chars = id.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    if !first.is_ascii_alphanumeric() {
        return false;
    }
    chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
}

fn valid_timestamp(ts: &str) -> bool {
    let b = ts.as_bytes();
    b.len() == 13
        && b[..8].iter().all(|c| c.is_ascii_digit())
        && b[8] == b'-'
        && b[9..13].iter().all(|c| c.is_ascii_digit())
}

fn current_local_timestamp() -> Result<String, B3Error> {
    #[cfg(windows)]
    {
        #[repr(C)]
        struct SystemTime {
            year: u16,
            month: u16,
            day_of_week: u16,
            day: u16,
            hour: u16,
            minute: u16,
            second: u16,
            milliseconds: u16,
        }
        extern "system" {
            fn GetLocalTime(lp_system_time: *mut SystemTime);
        }
        let mut st = SystemTime {
            year: 0,
            month: 0,
            day_of_week: 0,
            day: 0,
            hour: 0,
            minute: 0,
            second: 0,
            milliseconds: 0,
        };
        // SAFETY: `GetLocalTime` writes a valid `SYSTEMTIME` struct provided by caller.
        unsafe {
            GetLocalTime(&mut st);
        }
        Ok(format!(
            "{:04}{:02}{:02}-{:02}{:02}",
            st.year, st.month, st.day, st.hour, st.minute
        ))
    }

    #[cfg(unix)]
    {
        use std::process::Command;
        let out = Command::new("date")
            .arg("+%Y%m%d-%H%M")
            .output()
            .map_err(|e| fail(format!("NEW_RUN_FAIL: unable to read clock: {e}"), 1))?;
        let ts = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if !out.status.success() || !valid_timestamp(&ts) {
            return Err(fail("NEW_RUN_FAIL: unable to format local timestamp", 1));
        }
        Ok(ts)
    }

    #[cfg(not(any(windows, unix)))]
    {
        Err(fail(
            "NEW_RUN_FAIL: unsupported target platform for local timestamp",
            1,
        ))
    }
}

fn read_current_run_id(ns_dir: &Path) -> Option<String> {
    let cur_file = ns_dir.join("CURRENT");
    if !cur_file.is_file() {
        return None;
    }
    fs::read_to_string(cur_file)
        .ok()
        .map(|s| s.trim().to_string())
}

fn read_run_status(run_dir: &Path) -> String {
    let prog = run_dir.join("progress.md");
    let Ok(raw) = fs::read_to_string(prog) else {
        return "unknown".to_string();
    };
    for line in raw.lines() {
        if let Some(after_dash) = line.strip_prefix('-') {
            let trimmed = after_dash.trim_start_matches([' ', '\t']);
            if let Some(after_key) = trimmed.strip_prefix("run_status:") {
                let val = after_key.trim();
                if !val.is_empty() {
                    return val.to_string();
                }
            }
        }
    }
    "unknown".to_string()
}

fn list_non_link_dir_names_desc(dir: &Path) -> Vec<String> {
    let Ok(entries) = fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut names = Vec::new();
    for entry in entries.flatten() {
        let p = entry.path();
        if is_reparse_or_symlink(&p) {
            continue;
        }
        if let Ok(meta) = fs::symlink_metadata(&p) {
            if meta.is_dir() {
                if let Some(name) = p.file_name().and_then(|n| n.to_str()) {
                    names.push(name.to_string());
                }
            }
        }
    }
    sort_ordinal(names, true)
}

/// Creates a new run directory under `.b3/<namespace>/runs/<id>` and updates `CURRENT`.
pub fn new_run(
    repo_root_raw: &str,
    slug: &str,
    timestamp: &str,
    namespace: &str,
) -> Result<String, B3Error> {
    if slug.trim().is_empty() {
        return Err(fail("NEW_RUN_FAIL: missing --slug", 1));
    }
    let clean_slug = sanitized_slug(slug);
    if clean_slug.is_empty() {
        return Err(fail("NEW_RUN_FAIL: slug has no alphanumeric characters", 1));
    }

    let ts = if timestamp.is_empty() {
        current_local_timestamp()?
    } else {
        timestamp.trim().to_string()
    };
    if !valid_timestamp(&ts) {
        return Err(fail(
            format!("NEW_RUN_FAIL: invalid timestamp '{ts}' (expected YYYYMMDD-HHMM)"),
            1,
        ));
    }

    let root = normalize_repo_root(repo_root_raw)?;
    let (_, ns_dir) = resolve_namespace_dir(&root, namespace)?;
    let runs_dir = ns_dir.join("runs");
    assert_runs_dirs_not_links(&root, &ns_dir, &runs_dir, "NEW_RUN_FAIL")?;

    fs::create_dir_all(&runs_dir).map_err(|e| {
        fail(
            format!("NEW_RUN_FAIL: failed to create runs directory: {e}"),
            1,
        )
    })?;

    let base_id = format!("{ts}-{clean_slug}");
    let mut candidate = base_id.clone();
    let mut suffix = 2u32;
    while runs_dir.join(&candidate).exists() {
        candidate = format!("{base_id}-{suffix}");
        suffix += 1;
    }

    let run_dir = runs_dir.join(&candidate);
    fs::create_dir_all(&run_dir).map_err(|e| {
        fail(
            format!("NEW_RUN_FAIL: failed to create run directory: {e}"),
            1,
        )
    })?;
    write_atomic_lf(&ns_dir.join("CURRENT"), &format!("{candidate}\n"))?;

    Ok(candidate)
}

/// Resolves the relative run path (from `CURRENT`, `--run-id`, or legacy fallback).
pub fn resolve_run(repo_root_raw: &str, run_id: &str, namespace: &str) -> Result<String, B3Error> {
    let root = normalize_repo_root(repo_root_raw)?;
    let (ns_trim, ns_dir) = resolve_namespace_dir(&root, namespace)?;
    let ns_rel = format!(".b3/{ns_trim}");
    let runs_dir = ns_dir.join("runs");
    assert_runs_dirs_not_links(&root, &ns_dir, &runs_dir, "RESOLVE_FAIL")?;

    let autodev_dir = root.join(".b3").join("autodev");
    let autodev_runs_dir = autodev_dir.join("runs");

    if !run_id.is_empty() {
        let trimmed = run_id.trim();
        if !valid_run_id(trimmed) {
            return Err(fail(format!("RESOLVE_FAIL: invalid run id '{run_id}'"), 1));
        }
        let target = runs_dir.join(trimmed);
        if target.is_dir() && !is_reparse_or_symlink(&target) {
            return Ok(format!("{ns_rel}/runs/{trimmed}"));
        }
        if ns_trim == "ship" {
            let legacy_target = autodev_runs_dir.join(trimmed);
            if legacy_target.is_dir() && !is_reparse_or_symlink(&legacy_target) {
                return Ok(format!(".b3/autodev/runs/{trimmed}"));
            }
        }
        return Err(fail(format!("RESOLVE_FAIL: run not found '{trimmed}'"), 1));
    }

    let cur_file = ns_dir.join("CURRENT");
    if cur_file.is_file() && !is_reparse_or_symlink(&cur_file) {
        let cur_id = fs::read_to_string(&cur_file)
            .map_err(|e| fail(format!("RESOLVE_FAIL: unable to read CURRENT: {e}"), 1))?
            .trim()
            .to_string();
        if !valid_run_id(&cur_id) {
            return Err(fail(
                format!("RESOLVE_FAIL: CURRENT contains invalid run id '{cur_id}'"),
                1,
            ));
        }
        let target = runs_dir.join(&cur_id);
        if !target.is_dir() || is_reparse_or_symlink(&target) {
            return Err(fail(
                format!("RESOLVE_FAIL: CURRENT points to missing run '{cur_id}'"),
                1,
            ));
        }
        return Ok(format!("{ns_rel}/runs/{cur_id}"));
    }

    if ns_trim == "ship" {
        if ns_dir.join("progress.md").is_file() {
            return Ok(".b3/ship".to_string());
        }
        let ad_cur_file = autodev_dir.join("CURRENT");
        if ad_cur_file.is_file() {
            let ac_id = fs::read_to_string(&ad_cur_file)
                .map_err(|e| fail(format!("RESOLVE_FAIL: unable to read CURRENT: {e}"), 1))?
                .trim()
                .to_string();
            if !valid_run_id(&ac_id) {
                return Err(fail(
                    format!("RESOLVE_FAIL: CURRENT contains invalid run id '{ac_id}'"),
                    1,
                ));
            }
            if !autodev_runs_dir.join(&ac_id).is_dir() {
                return Err(fail(
                    format!("RESOLVE_FAIL: CURRENT points to missing run '{ac_id}'"),
                    1,
                ));
            }
            return Ok(format!(".b3/autodev/runs/{ac_id}"));
        }
        if autodev_dir.join("progress.md").is_file() {
            return Ok(".b3/autodev".to_string());
        }
    }

    Err(fail("NO_ACTIVE_RUN", 1))
}

/// Lists available runs for `namespace`, marking the `CURRENT` run with `* `.
pub fn list_runs(repo_root_raw: &str, namespace: &str) -> Result<String, B3Error> {
    let root = normalize_repo_root(repo_root_raw)?;
    let (ns_trim, ns_dir) = resolve_namespace_dir(&root, namespace)?;
    let runs_dir = ns_dir.join("runs");
    assert_runs_dirs_not_links(&root, &ns_dir, &runs_dir, "LIST_FAIL")?;

    let cur_id = read_current_run_id(&ns_dir);
    let dir_names = if runs_dir.is_dir() {
        list_non_link_dir_names_desc(&runs_dir)
    } else {
        Vec::new()
    };

    if !dir_names.is_empty() {
        let mut lines = Vec::with_capacity(dir_names.len());
        for id in dir_names {
            let st = read_run_status(&runs_dir.join(&id));
            let mark = if cur_id.as_deref() == Some(id.as_str()) {
                "* "
            } else {
                "  "
            };
            lines.push(format!("{mark}{id} [{st}]"));
        }
        return Ok(lines.join("\n"));
    }

    if ns_trim == "ship" {
        if ns_dir.join("progress.md").is_file() {
            let st = read_run_status(&ns_dir);
            return Ok(format!("* legacy [{st}]"));
        }
        let autodev_dir = root.join(".b3").join("autodev");
        let autodev_runs_dir = autodev_dir.join("runs");
        let ad_cur = read_current_run_id(&autodev_dir);
        let ad_names = if autodev_runs_dir.is_dir() {
            list_non_link_dir_names_desc(&autodev_runs_dir)
        } else {
            Vec::new()
        };
        if !ad_names.is_empty() {
            let mut lines = Vec::with_capacity(ad_names.len());
            for id in ad_names {
                let st = read_run_status(&autodev_runs_dir.join(&id));
                let mark = if ad_cur.as_deref() == Some(id.as_str()) {
                    "* "
                } else {
                    "  "
                };
                lines.push(format!("{mark}{id} [{st}] (legacy-autodev)"));
            }
            return Ok(lines.join("\n"));
        }
        if autodev_dir.join("progress.md").is_file() {
            let st = read_run_status(&autodev_dir);
            return Ok(format!("* legacy (legacy-autodev) [{st}]"));
        }
    }

    Ok("NO_RUNS".to_string())
}

/// Removes completed (`PASS`) runs older than `keep`, never deleting `CURRENT`
/// or runs with any non-`PASS` status.
pub fn prune(repo_root_raw: &str, keep: i32, namespace: &str) -> Result<String, B3Error> {
    if keep < 0 {
        return Err(fail("PRUNE_FAIL: --keep must be >= 0", 1));
    }
    let keep_usize = keep as usize;
    let root = normalize_repo_root(repo_root_raw)?;
    let (_, ns_dir) = resolve_namespace_dir(&root, namespace)?;
    let runs_dir = ns_dir.join("runs");
    assert_runs_dirs_not_links(&root, &ns_dir, &runs_dir, "PRUNE_FAIL")?;

    if !runs_dir.is_dir() {
        return Ok("PRUNE_OK: 0 removed".to_string());
    }

    let cur_id = read_current_run_id(&ns_dir);
    let dir_names = list_non_link_dir_names_desc(&runs_dir);
    let mut pass_count = 0usize;
    let mut pruned = Vec::new();

    for id in dir_names {
        let full_dir = runs_dir.join(&id);
        let st = read_run_status(&full_dir);
        let is_current = cur_id.as_deref() == Some(id.as_str());
        if st == "PASS" {
            pass_count += 1;
            if pass_count > keep_usize && !is_current {
                remove_dir_tree_safely(&full_dir)?;
                pruned.push(id);
            }
        }
    }

    if pruned.is_empty() {
        Ok("PRUNE_OK: 0 removed".to_string())
    } else {
        let mut lines: Vec<String> = pruned.iter().map(|p| format!("pruned: {p}")).collect();
        lines.push(format!("PRUNE_OK: {} removed", pruned.len()));
        Ok(lines.join("\n"))
    }
}
