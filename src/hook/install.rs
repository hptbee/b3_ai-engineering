use std::ffi::OsString;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use crate::adapters::common::{
    assert_regular_dir_or_missing, assert_regular_file_or_missing, normalize_abs_path_str,
    resolve_user_home_dir,
};
use crate::error::{fail, B3Error};
use crate::fs::{
    has_control_chars, is_reparse_or_symlink, next_tmp_suffix, resolve_unresolved_path,
    write_atomic_lf,
};
use crate::git::run_git;
use crate::hook::config::{
    default_global_preferences_path, default_project_preferences_path, resolve_hook_config,
};
use crate::json::{parse_json, JsonValue};

const GIT_HOOK_MARKER: &str = "# b3-native-guard-hook";
const GIT_HOOK_NAMES: &[&str] = &["pre-commit", "pre-push", "pre-merge-commit"];

/// Target host for `b3 hook install` / `uninstall` / `verify`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HookHostTarget {
    Cursor,
    Claude,
    Codex,
    Antigravity,
    Git,
    All,
}

impl HookHostTarget {
    /// Parses a host target (`cursor`, `claude`, `codex`, `antigravity`, `git`, `all`).
    pub fn parse(raw: &str) -> Result<Self, B3Error> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "cursor" => Ok(Self::Cursor),
            "claude" | "claude-code" | "claude_code" => Ok(Self::Claude),
            "codex" => Ok(Self::Codex),
            "antigravity" | "agy" => Ok(Self::Antigravity),
            "git" => Ok(Self::Git),
            "all" => Ok(Self::All),
            _ => Err(fail(
                format!(
                    "HOOK_INSTALL_FAIL: unsupported host target '{raw}'; expected cursor, claude, codex, antigravity, git, or all"
                ),
                1,
            )),
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Cursor => "cursor",
            Self::Claude => "claude",
            Self::Codex => "codex",
            Self::Antigravity => "antigravity",
            Self::Git => "git",
            Self::All => "all",
        }
    }
}

/// Installation scope for hooks.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HookScope {
    Project,
    Global,
}

impl HookScope {
    /// Parses a hook scope (`project` or `global`).
    pub fn parse(raw: &str) -> Result<Self, B3Error> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "project" | "local" => Ok(Self::Project),
            "global" | "user" => Ok(Self::Global),
            _ => Err(fail(
                format!("HOOK_INSTALL_FAIL: invalid scope '{raw}'; expected project or global"),
                1,
            )),
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Project => "project",
            Self::Global => "global",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum JsonHost {
    Cursor,
    Claude,
    Codex,
    Antigravity,
}

impl JsonHost {
    fn as_str(self) -> &'static str {
        match self {
            Self::Cursor => "cursor",
            Self::Claude => "claude",
            Self::Codex => "codex",
            Self::Antigravity => "antigravity",
        }
    }

    fn config_path(
        self,
        scope: HookScope,
        repo_root: Option<&Path>,
        user_home: &Path,
    ) -> Result<PathBuf, B3Error> {
        let base = match scope {
            HookScope::Project => resolve_project_root_dir(repo_root)?,
            HookScope::Global => user_home.to_path_buf(),
        };
        let path = match (self, scope) {
            (Self::Cursor, _) => base.join(".cursor").join("hooks.json"),
            (Self::Claude, _) => base.join(".claude").join("settings.json"),
            (Self::Codex, _) => base.join(".codex").join("hooks.json"),
            (Self::Antigravity, HookScope::Project) => base.join(".agents").join("hooks.json"),
            (Self::Antigravity, HookScope::Global) => {
                base.join(".gemini").join("config").join("hooks.json")
            }
        };
        Ok(path)
    }

    fn event_specs(self) -> &'static [(&'static str, Option<&'static str>)] {
        match self {
            Self::Cursor => &[
                ("preToolUse", None),
                ("beforeShellExecution", None),
                ("afterFileEdit", None),
                ("subagentStop", None),
                ("stop", None),
            ],
            Self::Claude => &[
                ("PreToolUse", Some("Edit|Write|MultiEdit|NotebookEdit|Bash")),
                ("PostToolUse", Some("Edit|Write|MultiEdit|NotebookEdit")),
                ("SubagentStop", None),
                ("Stop", None),
            ],
            Self::Codex => &[
                ("PreToolUse", Some("apply_patch|Write|Edit|Bash|shell")),
                ("PostToolUse", Some("apply_patch|Write|Edit")),
                ("Stop", None),
            ],
            Self::Antigravity => &[
                (
                    "PreToolUse",
                    Some("write_to_file|write_file|edit_file|replace_file_content|multi_replace_file_content|run_command"),
                ),
                (
                    "PostToolUse",
                    Some("write_to_file|write_file|edit_file|replace_file_content|multi_replace_file_content"),
                ),
                ("Stop", None),
            ],
        }
    }
}

fn resolve_project_root_dir(repo_root: Option<&Path>) -> Result<PathBuf, B3Error> {
    let raw = match repo_root {
        Some(p) if !p.as_os_str().is_empty() => p.to_path_buf(),
        _ => std::env::current_dir()
            .map_err(|e| fail(format!("HOOK_INSTALL_FAIL: cannot resolve cwd: {e}"), 1))?,
    };
    let s = raw.to_string_lossy();
    if has_control_chars(&s) {
        return Err(fail(
            "HOOK_INSTALL_FAIL: control characters rejected in repo_root",
            1,
        ));
    }
    let abs = if raw.is_absolute() {
        resolve_unresolved_path(&raw, ".")
    } else {
        let cwd = std::env::current_dir()
            .map_err(|e| fail(format!("HOOK_INSTALL_FAIL: cannot resolve cwd: {e}"), 1))?;
        resolve_unresolved_path(&cwd, &s)
    };
    Ok(PathBuf::from(normalize_abs_path_str(&abs)))
}

fn resolve_b3_bin_str(explicit: Option<&str>) -> Result<String, B3Error> {
    if let Some(raw) = explicit.map(str::trim).filter(|s| !s.is_empty()) {
        if has_control_chars(raw) {
            return Err(fail(
                "HOOK_INSTALL_FAIL: control characters rejected in b3_bin",
                1,
            ));
        }
        return Ok(raw.to_string());
    }
    if let Ok(exe) = std::env::current_exe() {
        let norm = normalize_abs_path_str(&exe);
        if !norm.is_empty() && !has_control_chars(&norm) {
            return Ok(norm);
        }
    }
    Ok("b3".to_string())
}

fn format_shell_bin_for_json(b3_bin: &str) -> String {
    let normalized = if cfg!(windows) && (b3_bin.contains('\\') || b3_bin.contains('/')) {
        b3_bin.replace('\\', "/")
    } else {
        b3_bin.to_string()
    };
    let needs_quotes = (cfg!(windows) && normalized.contains('/'))
        || normalized.chars().any(|c| {
            c.is_whitespace()
                || matches!(
                    c,
                    '"' | '\'' | '$' | '`' | '&' | '|' | ';' | '(' | ')' | '<' | '>' | '\\'
                )
                || !c.is_ascii()
        });
    if !needs_quotes {
        return normalized;
    }
    let mut out = String::with_capacity(normalized.len() + 4);
    out.push('"');
    for ch in normalized.chars() {
        if matches!(ch, '"' | '\\' | '$' | '`') {
            out.push('\\');
        }
        out.push(ch);
    }
    out.push('"');
    out
}

fn format_json_hook_command(b3_bin: &str, host: JsonHost, event_name: &str) -> String {
    let bin = format_shell_bin_for_json(b3_bin);
    format!(
        "{bin} hook run --host {} --event {event_name}",
        host.as_str()
    )
}

fn sh_single_quote(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len() + 2);
    out.push('\'');
    for ch in raw.chars() {
        if ch == '\'' {
            out.push_str("'\\''");
        } else {
            out.push(ch);
        }
    }
    out.push('\'');
    out
}

fn is_b3_managed_command(cmd: &str) -> bool {
    let trimmed = cmd.trim();
    if trimmed.is_empty() {
        return false;
    }
    if trimmed.contains("b3 hook run") {
        return true;
    }
    // Also recognize quoted/full paths ending in `b3` or `b3.exe`, e.g. `"C:/.../b3.exe" hook run ...`
    let mut i = 0usize;
    let bytes = trimmed.as_bytes();
    while i < bytes.len() && bytes[i].is_ascii_whitespace() {
        i += 1;
    }
    let first_tok = if i < bytes.len() && (bytes[i] == b'"' || bytes[i] == b'\'') {
        let q = bytes[i];
        i += 1;
        let start = i;
        while i < bytes.len() && bytes[i] != q {
            if bytes[i] == b'\\' && q == b'"' && i + 1 < bytes.len() {
                i += 2;
            } else {
                i += 1;
            }
        }
        let slice = &trimmed[start..i];
        if i < bytes.len() {
            i += 1;
        }
        slice
    } else {
        let start = i;
        while i < bytes.len() && !bytes[i].is_ascii_whitespace() {
            i += 1;
        }
        &trimmed[start..i]
    };

    let base = first_tok
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or("")
        .to_ascii_lowercase();
    let is_b3_bin = base == "b3" || base == "b3.exe";
    let rest = trimmed[i..].trim_start();
    is_b3_bin && (rest == "hook run" || rest.starts_with("hook run "))
}

fn backup_path_for(dest: &Path) -> PathBuf {
    let mut os: OsString = dest.as_os_str().to_os_string();
    os.push(".b3-backup");
    PathBuf::from(os)
}

fn write_raw_bytes_atomic(dest: &Path, bytes: &[u8]) -> Result<(), B3Error> {
    assert_regular_file_or_missing(dest, "backup file")?;
    if let Some(parent) = dest.parent() {
        if !parent.as_os_str().is_empty() && !parent.exists() {
            fs::create_dir_all(parent).map_err(|e| {
                fail(
                    format!(
                        "HOOK_INSTALL_FAIL: failed creating directory {}: {e}",
                        parent.display()
                    ),
                    1,
                )
            })?;
        }
    }
    let file_name = dest
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or_else(|| fail("HOOK_INSTALL_FAIL: invalid backup path", 1))?;
    let tmp = dest.with_file_name(format!("{file_name}.tmp.{}", next_tmp_suffix()));
    let mut f = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&tmp)
        .map_err(|e| {
            fail(
                format!("HOOK_INSTALL_FAIL: failed creating temp backup: {e}"),
                1,
            )
        })?;
    if let Err(e) = f.write_all(bytes).and_then(|_| f.flush()) {
        drop(f);
        let _ = fs::remove_file(&tmp);
        return Err(fail(
            format!(
                "HOOK_INSTALL_FAIL: failed writing backup {}: {e}",
                dest.display()
            ),
            1,
        ));
    }
    drop(f);
    if let Err(e) = fs::rename(&tmp, dest) {
        let _ = fs::remove_file(&tmp);
        return Err(fail(
            format!(
                "HOOK_INSTALL_FAIL: failed committing backup {}: {e}",
                dest.display()
            ),
            1,
        ));
    }
    Ok(())
}

fn assert_safe_config_ancestors(dest: &Path, stop_at: &Path) -> Result<(), B3Error> {
    assert_regular_file_or_missing(dest, "hook config")?;
    let mut cur = dest.parent();
    while let Some(dir) = cur {
        if dir == stop_at {
            break;
        }
        assert_regular_dir_or_missing(dir, "hook config directory")?;
        cur = dir.parent();
    }
    Ok(())
}

fn upsert_json_key(entries: &mut Vec<(String, JsonValue)>, key: &str, val: JsonValue) {
    if let Some((_, existing)) = entries.iter_mut().find(|(k, _)| k == key) {
        *existing = val;
    } else {
        entries.push((key.to_string(), val));
    }
}

fn take_or_init_object_entries(
    entries: &mut [(String, JsonValue)],
    key: &str,
) -> Result<Vec<(String, JsonValue)>, B3Error> {
    if let Some((_, val)) = entries.iter_mut().find(|(k, _)| k == key) {
        let JsonValue::Object(inner) = val else {
            return Err(fail(
                format!("HOOK_INSTALL_FAIL: expected JSON object at key '{key}'"),
                1,
            ));
        };
        Ok(std::mem::take(inner))
    } else {
        Ok(Vec::new())
    }
}

fn take_or_init_array(
    entries: &mut [(String, JsonValue)],
    key: &str,
) -> Result<Vec<JsonValue>, B3Error> {
    if let Some((_, val)) = entries.iter_mut().find(|(k, _)| k == key) {
        let JsonValue::Array(arr) = val else {
            return Err(fail(
                format!("HOOK_INSTALL_FAIL: expected JSON array at key '{key}'"),
                1,
            ));
        };
        Ok(std::mem::take(arr))
    } else {
        Ok(Vec::new())
    }
}

fn make_nested_hook_group(matcher: Option<&str>, command: &str) -> JsonValue {
    let inner_hook = JsonValue::obj(vec![
        ("type".into(), JsonValue::str("command")),
        ("command".into(), JsonValue::str(command)),
    ]);
    let mut group_entries = Vec::new();
    if let Some(m) = matcher {
        group_entries.push(("matcher".into(), JsonValue::str(m)));
    }
    group_entries.push(("hooks".into(), JsonValue::Array(vec![inner_hook])));
    JsonValue::Object(group_entries)
}

fn make_cursor_hook_entry(command: &str) -> JsonValue {
    JsonValue::obj(vec![("command".into(), JsonValue::str(command))])
}

fn entry_has_exact_b3_cmd(item: &JsonValue, expected_cmd: &str, flat_only: bool) -> bool {
    if let Some(cmd) = item.get("command").and_then(JsonValue::as_str) {
        if cmd == expected_cmd {
            return true;
        }
    }
    if !flat_only {
        if let Some(hooks) = item.get("hooks").and_then(JsonValue::as_array) {
            for h in hooks {
                if h.get("command").and_then(JsonValue::as_str) == Some(expected_cmd) {
                    return true;
                }
            }
        }
    }
    false
}

fn entry_has_any_b3_cmd(item: &JsonValue, flat_only: bool) -> bool {
    if item
        .get("command")
        .and_then(JsonValue::as_str)
        .is_some_and(is_b3_managed_command)
    {
        return true;
    }
    if !flat_only {
        if let Some(hooks) = item.get("hooks").and_then(JsonValue::as_array) {
            if hooks.iter().any(|h| {
                h.get("command")
                    .and_then(JsonValue::as_str)
                    .is_some_and(is_b3_managed_command)
            }) {
                return true;
            }
        }
    }
    false
}

fn upsert_event_array(
    arr: &mut Vec<JsonValue>,
    matcher: Option<&str>,
    expected_cmd: &str,
    flat_cursor: bool,
) -> bool {
    if arr
        .iter()
        .any(|item| entry_has_exact_b3_cmd(item, expected_cmd, flat_cursor))
    {
        return false;
    }

    // Update any existing B3-managed entry in place if command changed (e.g. different b3_bin)
    for item in arr.iter_mut() {
        if entry_has_any_b3_cmd(item, flat_cursor) {
            *item = if flat_cursor {
                make_cursor_hook_entry(expected_cmd)
            } else {
                make_nested_hook_group(matcher, expected_cmd)
            };
            return true;
        }
    }

    arr.push(if flat_cursor {
        make_cursor_hook_entry(expected_cmd)
    } else {
        make_nested_hook_group(matcher, expected_cmd)
    });
    true
}

fn remove_b3_from_event_array(arr: &mut Vec<JsonValue>) -> usize {
    let mut removed = 0usize;
    let mut kept = Vec::with_capacity(arr.len());
    for item in arr.drain(..) {
        if item
            .get("command")
            .and_then(JsonValue::as_str)
            .is_some_and(is_b3_managed_command)
        {
            removed += 1;
            continue;
        }
        if let JsonValue::Object(mut obj_entries) = item {
            if let Some((_, JsonValue::Array(inner))) =
                obj_entries.iter_mut().find(|(k, _)| k == "hooks")
            {
                let orig_len = inner.len();
                inner.retain(|h| {
                    !h.get("command")
                        .and_then(JsonValue::as_str)
                        .is_some_and(is_b3_managed_command)
                });
                let diff = orig_len - inner.len();
                removed += diff;
                if diff > 0 && inner.is_empty() {
                    // Drop the wrapper group when its only entries were B3-managed.
                    continue;
                }
            }
            kept.push(JsonValue::Object(obj_entries));
        } else {
            kept.push(item);
        }
    }
    *arr = kept;
    removed
}

fn install_events_into_map(
    map_entries: &mut Vec<(String, JsonValue)>,
    host: JsonHost,
    b3_bin: &str,
    flat_cursor: bool,
) -> Result<bool, B3Error> {
    let mut changed = false;
    for &(event_name, matcher) in host.event_specs() {
        let cmd = format_json_hook_command(b3_bin, host, event_name);
        let mut arr = take_or_init_array(map_entries, event_name)?;
        if upsert_event_array(&mut arr, matcher, &cmd, flat_cursor) {
            changed = true;
        }
        upsert_json_key(map_entries, event_name, JsonValue::Array(arr));
    }
    Ok(changed)
}

fn remove_events_from_map(map_entries: &mut Vec<(String, JsonValue)>, events: &[&str]) -> usize {
    let mut removed = 0usize;
    for &ev in events {
        if let Some(pos) = map_entries.iter().position(|(k, _)| k == ev) {
            if let JsonValue::Array(arr) = &mut map_entries[pos].1 {
                let r = remove_b3_from_event_array(arr);
                removed += r;
                if r > 0 && arr.is_empty() {
                    map_entries.remove(pos);
                }
            }
        }
    }
    removed
}

fn apply_json_install(
    host: JsonHost,
    root: &JsonValue,
    b3_bin: &str,
) -> Result<(JsonValue, bool), B3Error> {
    let JsonValue::Object(mut root_entries) = root.clone() else {
        return Err(fail(
            "HOOK_INSTALL_FAIL: config root must be a JSON object",
            1,
        ));
    };

    let changed = match host {
        JsonHost::Cursor => {
            let mut chg = false;
            if !root_entries.iter().any(|(k, _)| k == "version") {
                root_entries.insert(0, ("version".into(), JsonValue::num_u64(1)));
                chg = true;
            }
            let mut hooks_entries = take_or_init_object_entries(&mut root_entries, "hooks")?;
            if install_events_into_map(&mut hooks_entries, host, b3_bin, true)? {
                chg = true;
            }
            upsert_json_key(&mut root_entries, "hooks", JsonValue::Object(hooks_entries));
            chg
        }
        JsonHost::Claude => {
            let mut hooks_entries = take_or_init_object_entries(&mut root_entries, "hooks")?;
            let chg = install_events_into_map(&mut hooks_entries, host, b3_bin, false)?;
            upsert_json_key(&mut root_entries, "hooks", JsonValue::Object(hooks_entries));
            chg
        }
        JsonHost::Codex => install_events_into_map(&mut root_entries, host, b3_bin, false)?,
        JsonHost::Antigravity => {
            let mut guard_entries =
                take_or_init_object_entries(&mut root_entries, "b3-native-guard")?;
            let chg = install_events_into_map(&mut guard_entries, host, b3_bin, false)?;
            upsert_json_key(
                &mut root_entries,
                "b3-native-guard",
                JsonValue::Object(guard_entries),
            );
            chg
        }
    };

    Ok((JsonValue::Object(root_entries), changed))
}

fn apply_json_uninstall(host: JsonHost, root: &JsonValue) -> Result<(JsonValue, usize), B3Error> {
    let JsonValue::Object(mut root_entries) = root.clone() else {
        return Err(fail(
            "HOOK_INSTALL_FAIL: config root must be a JSON object",
            1,
        ));
    };
    let ev_names: Vec<&str> = host.event_specs().iter().map(|(e, _)| *e).collect();

    let removed = match host {
        JsonHost::Cursor | JsonHost::Claude => {
            if let Some(pos) = root_entries.iter().position(|(k, _)| k == "hooks") {
                if let JsonValue::Object(ref mut hooks_entries) = root_entries[pos].1 {
                    let r = remove_events_from_map(hooks_entries, &ev_names);
                    if r > 0 && hooks_entries.is_empty() && host == JsonHost::Claude {
                        root_entries.remove(pos);
                    }
                    r
                } else {
                    0
                }
            } else {
                0
            }
        }
        JsonHost::Codex => remove_events_from_map(&mut root_entries, &ev_names),
        JsonHost::Antigravity => {
            if let Some(pos) = root_entries
                .iter()
                .position(|(k, _)| k == "b3-native-guard")
            {
                if let JsonValue::Object(ref mut guard_entries) = root_entries[pos].1 {
                    let r = remove_events_from_map(guard_entries, &ev_names);
                    if r > 0 && guard_entries.is_empty() {
                        root_entries.remove(pos);
                    }
                    r
                } else {
                    0
                }
            } else {
                0
            }
        }
    };

    Ok((JsonValue::Object(root_entries), removed))
}

fn verify_json_config_value(host: JsonHost, root: &JsonValue) -> Vec<String> {
    let mut missing = Vec::new();
    let container = match host {
        JsonHost::Cursor | JsonHost::Claude => root.get("hooks"),
        JsonHost::Codex => Some(root),
        JsonHost::Antigravity => root.get("b3-native-guard"),
    };
    let flat_only = host == JsonHost::Cursor;
    for &(ev_name, _) in host.event_specs() {
        let ok = container
            .and_then(|c| c.get(ev_name))
            .and_then(JsonValue::as_array)
            .is_some_and(|arr| arr.iter().any(|item| entry_has_any_b3_cmd(item, flat_only)));
        if !ok {
            missing.push(ev_name.to_string());
        }
    }
    missing
}

fn write_json_with_backup_rollback(
    dest: &Path,
    new_json: &JsonValue,
    existing_bytes: Option<&[u8]>,
) -> Result<(), B3Error> {
    let pretty = format!("{}\n", new_json.to_json_pretty());
    if let Some(orig) = existing_bytes {
        let backup = backup_path_for(dest);
        write_raw_bytes_atomic(&backup, orig)?;
        if let Err(err) = write_atomic_lf(dest, &pretty) {
            let _ = write_raw_bytes_atomic(dest, orig);
            return Err(err);
        }
    } else {
        write_atomic_lf(dest, &pretty)?;
    }
    Ok(())
}

fn install_json_host(
    host: JsonHost,
    scope: HookScope,
    repo_root: Option<&Path>,
    user_home: &Path,
    b3_bin: &str,
    dry_run: bool,
) -> Result<String, B3Error> {
    let stop_at = match scope {
        HookScope::Project => resolve_project_root_dir(repo_root)?,
        HookScope::Global => user_home.to_path_buf(),
    };
    let dest = host.config_path(scope, repo_root, user_home)?;
    assert_safe_config_ancestors(&dest, &stop_at)?;

    let existing_bytes = if dest.exists() {
        Some(fs::read(&dest).map_err(|e| {
            fail(
                format!("HOOK_INSTALL_FAIL: cannot read {}: {e}", dest.display()),
                1,
            )
        })?)
    } else {
        None
    };

    let current_val = match &existing_bytes {
        Some(bytes) => {
            let raw = std::str::from_utf8(bytes).map_err(|_| {
                fail(
                    format!("HOOK_INSTALL_FAIL: non-UTF-8 config at {}", dest.display()),
                    1,
                )
            })?;
            let parsed = parse_json(raw).map_err(|e| {
                fail(
                    format!("HOOK_INSTALL_FAIL: invalid JSON in {}: {e}", dest.display()),
                    1,
                )
            })?;
            if !parsed.is_object() {
                return Err(fail(
                    format!(
                        "HOOK_INSTALL_FAIL: expected JSON object in {}",
                        dest.display()
                    ),
                    1,
                ));
            }
            parsed
        }
        None => JsonValue::Object(Vec::new()),
    };

    let (updated, changed) = apply_json_install(host, &current_val, b3_bin)?;
    if !changed {
        return Ok(format!(
            "{} ({}): unchanged ({})",
            host.as_str(),
            scope.as_str(),
            dest.display()
        ));
    }

    if dry_run {
        return Ok(format!(
            "dry-run: {} ({}) -> {}",
            host.as_str(),
            scope.as_str(),
            dest.display()
        ));
    }

    write_json_with_backup_rollback(&dest, &updated, existing_bytes.as_deref())?;
    let verb = if existing_bytes.is_some() {
        "updated"
    } else {
        "created"
    };
    Ok(format!(
        "{} ({}): {verb} ({})",
        host.as_str(),
        scope.as_str(),
        dest.display()
    ))
}

fn uninstall_json_host(
    host: JsonHost,
    scope: HookScope,
    repo_root: Option<&Path>,
    user_home: &Path,
    dry_run: bool,
) -> Result<String, B3Error> {
    let stop_at = match scope {
        HookScope::Project => resolve_project_root_dir(repo_root)?,
        HookScope::Global => user_home.to_path_buf(),
    };
    let dest = host.config_path(scope, repo_root, user_home)?;
    assert_safe_config_ancestors(&dest, &stop_at)?;
    if !dest.exists() {
        return Ok(format!(
            "{} ({}): not installed ({})",
            host.as_str(),
            scope.as_str(),
            dest.display()
        ));
    }

    let orig_bytes = fs::read(&dest).map_err(|e| {
        fail(
            format!("HOOK_INSTALL_FAIL: cannot read {}: {e}", dest.display()),
            1,
        )
    })?;
    let raw = std::str::from_utf8(&orig_bytes).map_err(|_| {
        fail(
            format!("HOOK_INSTALL_FAIL: non-UTF-8 config at {}", dest.display()),
            1,
        )
    })?;
    let parsed = parse_json(raw).map_err(|e| {
        fail(
            format!("HOOK_INSTALL_FAIL: invalid JSON in {}: {e}", dest.display()),
            1,
        )
    })?;
    let (updated, removed) = apply_json_uninstall(host, &parsed)?;
    if removed == 0 {
        return Ok(format!(
            "{} ({}): nothing to remove ({})",
            host.as_str(),
            scope.as_str(),
            dest.display()
        ));
    }

    if dry_run {
        return Ok(format!(
            "dry-run: uninstall {} ({}) removed={removed} ({})",
            host.as_str(),
            scope.as_str(),
            dest.display()
        ));
    }

    write_json_with_backup_rollback(&dest, &updated, Some(&orig_bytes))?;
    Ok(format!(
        "{} ({}): removed={removed} ({})",
        host.as_str(),
        scope.as_str(),
        dest.display()
    ))
}

fn verify_json_host(
    host: JsonHost,
    scope: HookScope,
    repo_root: Option<&Path>,
    user_home: &Path,
) -> Result<(String, bool), B3Error> {
    let dest = host.config_path(scope, repo_root, user_home)?;
    if is_reparse_or_symlink(&dest) {
        return Ok((
            format!(
                "VERIFY_ERROR: {} ({}) config is a symlink/reparse point: {}",
                host.as_str(),
                scope.as_str(),
                dest.display()
            ),
            false,
        ));
    }
    if !dest.is_file() {
        return Ok((
            format!(
                "VERIFY_MISSING: {} ({}) config not found: {}",
                host.as_str(),
                scope.as_str(),
                dest.display()
            ),
            false,
        ));
    }
    let raw = match fs::read_to_string(&dest) {
        Ok(s) => s,
        Err(e) => {
            return Ok((
                format!(
                    "VERIFY_ERROR: {} ({}) unreadable {}: {e}",
                    host.as_str(),
                    scope.as_str(),
                    dest.display()
                ),
                false,
            ));
        }
    };
    let parsed = match parse_json(&raw) {
        Ok(v) if v.is_object() => v,
        Ok(_) => {
            return Ok((
                format!(
                    "VERIFY_ERROR: {} ({}) config is not a JSON object: {}",
                    host.as_str(),
                    scope.as_str(),
                    dest.display()
                ),
                false,
            ));
        }
        Err(e) => {
            return Ok((
                format!(
                    "VERIFY_ERROR: {} ({}) invalid JSON {}: {e}",
                    host.as_str(),
                    scope.as_str(),
                    dest.display()
                ),
                false,
            ));
        }
    };

    let missing = verify_json_config_value(host, &parsed);
    if missing.is_empty() {
        Ok((
            format!(
                "VERIFY_OK: {} ({}) ({})",
                host.as_str(),
                scope.as_str(),
                dest.display()
            ),
            true,
        ))
    } else {
        Ok((
            format!(
                "VERIFY_MISSING: {} ({}) missing hooks [{}] in {}",
                host.as_str(),
                scope.as_str(),
                missing.join(", "),
                dest.display()
            ),
            false,
        ))
    }
}

fn norm_cmp_path(p: &Path) -> String {
    let s = normalize_abs_path_str(p)
        .replace('\\', "/")
        .trim_end_matches('/')
        .to_string();
    if cfg!(windows) {
        s.to_ascii_lowercase()
    } else {
        s
    }
}

fn is_path_within_dir(candidate: &Path, parent: &Path) -> bool {
    let cand_norm = norm_cmp_path(candidate);
    let parent_norm = norm_cmp_path(parent);
    cand_norm == parent_norm || cand_norm.starts_with(&format!("{parent_norm}/"))
}

fn assert_no_reparse_ancestors_within(base: &Path, target: &Path) -> Result<(), B3Error> {
    let base_norm = norm_cmp_path(base);
    let target_norm = norm_cmp_path(target);
    let rel = if target_norm == base_norm {
        ""
    } else if let Some(rest) = target_norm.strip_prefix(&format!("{base_norm}/")) {
        rest
    } else {
        return Ok(());
    };
    let mut cur = base.to_path_buf();
    if is_reparse_or_symlink(&cur) {
        return Err(fail(
            format!(
                "HOOK_INSTALL_FAIL: symlink/reparse point in repository path: {}",
                cur.display()
            ),
            1,
        ));
    }
    for seg in rel.split('/').filter(|s| !s.is_empty()) {
        cur.push(seg);
        if is_reparse_or_symlink(&cur) {
            return Err(fail(
                format!(
                    "HOOK_INSTALL_FAIL: symlink/reparse point in hooks ancestor path: {}",
                    cur.display()
                ),
                1,
            ));
        }
    }
    Ok(())
}

fn resolve_git_hooks_dir(repo_root: &Path) -> Result<PathBuf, B3Error> {
    let no_env: [(&str, &str); 0] = [];
    let top_res = run_git(repo_root, &["rev-parse", "--show-toplevel"], &no_env, None)?;
    if top_res.exit_code != 0 {
        return Err(fail(
            format!(
                "HOOK_INSTALL_FAIL: not a git repository: {}",
                repo_root.display()
            ),
            1,
        ));
    }
    let toplevel_raw = String::from_utf8_lossy(&top_res.stdout).trim().to_string();
    let toplevel_dir = resolve_unresolved_path(repo_root, &toplevel_raw);

    let common_res = run_git(repo_root, &["rev-parse", "--git-common-dir"], &no_env, None)?;
    let common_raw = String::from_utf8_lossy(&common_res.stdout)
        .trim()
        .to_string();
    if common_res.exit_code != 0 || common_raw.is_empty() {
        return Err(fail(
            "HOOK_INSTALL_FAIL: failed to resolve git common dir",
            1,
        ));
    }
    let common_dir = resolve_unresolved_path(repo_root, &common_raw);

    // Only honor repo-local core.hooksPath; never write into global/system core.hooksPath
    // during project-scoped installation.
    let hp_res = run_git(
        repo_root,
        &["config", "--local", "--get", "core.hooksPath"],
        &no_env,
        None,
    )?;
    if hp_res.exit_code == 0 {
        let hp = String::from_utf8_lossy(&hp_res.stdout).trim().to_string();
        if !hp.is_empty() {
            let p = Path::new(&hp);
            let resolved = if p.is_absolute() {
                resolve_unresolved_path(p, ".")
            } else {
                resolve_unresolved_path(&toplevel_dir, &hp)
            };
            if is_path_within_dir(&resolved, &toplevel_dir) {
                assert_no_reparse_ancestors_within(&toplevel_dir, &resolved)?;
            } else if is_path_within_dir(&resolved, &common_dir) {
                assert_no_reparse_ancestors_within(&common_dir, &resolved)?;
            } else {
                return Err(fail(
                    format!(
                        "HOOK_INSTALL_FAIL: local core.hooksPath escapes repository scope: {}",
                        resolved.display()
                    ),
                    1,
                ));
            }
            return Ok(PathBuf::from(normalize_abs_path_str(&resolved)));
        }
    }

    let default_hooks = common_dir.join("hooks");
    assert_no_reparse_ancestors_within(&common_dir, &default_hooks)?;
    Ok(PathBuf::from(normalize_abs_path_str(&default_hooks)))
}

fn build_git_hook_shim(hook_name: &str, b3_bin: &str, repo_root: &Path) -> String {
    let bin_for_sh = if cfg!(windows) && (b3_bin.contains('\\') || b3_bin.contains('/')) {
        b3_bin.replace('\\', "/")
    } else {
        b3_bin.to_string()
    };
    let root_for_sh = normalize_abs_path_str(repo_root).replace('\\', "/");
    let bin_q = sh_single_quote(&bin_for_sh);
    let root_q = sh_single_quote(&root_for_sh);
    let user_hook_rel = sh_single_quote(&format!("{hook_name}.b3-user"));

    [
        "#!/bin/sh".to_string(),
        format!("{GIT_HOOK_MARKER} v1 ({hook_name})"),
        format!("B3_BIN={bin_q}"),
        format!("DEFAULT_REPO_ROOT={root_q}"),
        "REPO_ROOT=\"$(git rev-parse --show-toplevel 2>/dev/null || true)\"".to_string(),
        "if [ -z \"$REPO_ROOT\" ]; then".to_string(),
        "  REPO_ROOT=\"$DEFAULT_REPO_ROOT\"".to_string(),
        "fi".to_string(),
        String::new(),
        "if [ \"${B3_HOOK_ACTIVE:-}\" != \"1\" ] && [ \"${B3_HOOK_ACTIVE:-}\" != \"true\" ]; then".to_string(),
        format!(
            "  \"$B3_BIN\" hook run --host git --event {hook_name} --repo-root \"$REPO_ROOT\" </dev/null"
        ),
        "  rc=$?".to_string(),
        "  if [ \"$rc\" -ne 0 ]; then".to_string(),
        "    exit \"$rc\"".to_string(),
        "  fi".to_string(),
        "fi".to_string(),
        String::new(),
        format!("USER_HOOK=\"$(dirname \"$0\")/\"{user_hook_rel}"),
        "if [ -x \"$USER_HOOK\" ]; then".to_string(),
        "  B3_HOOK_ACTIVE=1 \"$USER_HOOK\" \"$@\"".to_string(),
        "  exit $?".to_string(),
        "elif [ -f \"$USER_HOOK\" ]; then".to_string(),
        "  B3_HOOK_ACTIVE=1 sh \"$USER_HOOK\" \"$@\"".to_string(),
        "  exit $?".to_string(),
        "fi".to_string(),
        "exit 0".to_string(),
    ]
    .join("\n")
        + "\n"
}

fn set_executable_if_unix(path: &Path) -> Result<(), B3Error> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let perms = fs::Permissions::from_mode(0o755);
        fs::set_permissions(path, perms).map_err(|e| {
            fail(
                format!(
                    "HOOK_INSTALL_FAIL: failed setting 0o755 on {}: {e}",
                    path.display()
                ),
                1,
            )
        })?;
    }
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}

fn is_b3_git_shim(content: &str) -> bool {
    content.contains(GIT_HOOK_MARKER)
}

fn install_git_hooks(
    repo_root: Option<&Path>,
    b3_bin: &str,
    dry_run: bool,
    force: bool,
) -> Result<String, B3Error> {
    let root = resolve_project_root_dir(repo_root)?;
    let hooks_dir = resolve_git_hooks_dir(&root)?;
    assert_regular_dir_or_missing(&hooks_dir, "git hooks directory")?;

    let mut details = Vec::new();
    for &hook_name in GIT_HOOK_NAMES {
        let hook_path = hooks_dir.join(hook_name);
        let user_backup = hooks_dir.join(format!("{hook_name}.b3-user"));
        assert_regular_file_or_missing(&hook_path, "git hook")?;
        assert_regular_file_or_missing(&user_backup, "git hook backup")?;

        let shim_text = build_git_hook_shim(hook_name, b3_bin, &root);
        let mut backed_up_now: Option<Vec<u8>> = None;

        if hook_path.exists() {
            let existing_bytes = fs::read(&hook_path).map_err(|e| {
                fail(
                    format!(
                        "HOOK_INSTALL_FAIL: cannot read existing hook {}: {e}",
                        hook_path.display()
                    ),
                    1,
                )
            })?;
            let existing_str = String::from_utf8_lossy(&existing_bytes);
            if is_b3_git_shim(&existing_str) {
                if existing_str == shim_text {
                    details.push(format!("{hook_name}=unchanged"));
                    continue;
                }
            } else {
                if user_backup.exists() {
                    let prev_backup = fs::read(&user_backup).map_err(|e| {
                        fail(
                            format!(
                                "HOOK_INSTALL_FAIL: cannot read backup {}: {e}",
                                user_backup.display()
                            ),
                            1,
                        )
                    })?;
                    if prev_backup != existing_bytes && !force {
                        return Err(fail(
                            format!(
                                "HOOK_INSTALL_FAIL: existing user hook backup differs at {} (re-run with --force to replace)",
                                user_backup.display()
                            ),
                            1,
                        ));
                    }
                }
                backed_up_now = Some(existing_bytes);
            }
        }

        if dry_run {
            let note = if backed_up_now.is_some() {
                "backup+install"
            } else {
                "install"
            };
            details.push(format!("{hook_name}=dry-run({note})"));
            continue;
        }

        if let Some(ref orig_bytes) = backed_up_now {
            write_raw_bytes_atomic(&user_backup, orig_bytes)?;
            set_executable_if_unix(&user_backup)?;
        }

        if let Err(err) = write_atomic_lf(&hook_path, &shim_text) {
            if let Some(ref orig_bytes) = backed_up_now {
                let _ = write_raw_bytes_atomic(&hook_path, orig_bytes);
                let _ = fs::remove_file(&user_backup);
            }
            return Err(err);
        }
        if let Err(err) = set_executable_if_unix(&hook_path) {
            if let Some(ref orig_bytes) = backed_up_now {
                let _ = write_raw_bytes_atomic(&hook_path, orig_bytes);
                let _ = fs::remove_file(&user_backup);
            }
            return Err(err);
        }

        details.push(if backed_up_now.is_some() {
            format!("{hook_name}=installed(chained .b3-user)")
        } else {
            format!("{hook_name}=installed")
        });
    }

    Ok(format!(
        "git (project): {} ({})",
        details.join(", "),
        hooks_dir.display()
    ))
}

fn uninstall_git_hooks(repo_root: Option<&Path>, dry_run: bool) -> Result<String, B3Error> {
    let root = resolve_project_root_dir(repo_root)?;
    let hooks_dir = resolve_git_hooks_dir(&root)?;
    if !hooks_dir.exists() {
        return Ok(format!(
            "git (project): not installed ({})",
            hooks_dir.display()
        ));
    }
    assert_regular_dir_or_missing(&hooks_dir, "git hooks directory")?;

    let mut details = Vec::new();
    for &hook_name in GIT_HOOK_NAMES {
        let hook_path = hooks_dir.join(hook_name);
        let user_backup = hooks_dir.join(format!("{hook_name}.b3-user"));
        assert_regular_file_or_missing(&hook_path, "git hook")?;
        assert_regular_file_or_missing(&user_backup, "git hook backup")?;

        if hook_path.exists() {
            let content = fs::read_to_string(&hook_path).map_err(|e| {
                fail(
                    format!(
                        "HOOK_INSTALL_FAIL: cannot read {}: {e}",
                        hook_path.display()
                    ),
                    1,
                )
            })?;
            if is_b3_git_shim(&content) {
                if dry_run {
                    let action = if user_backup.is_file() {
                        "dry-run(remove+restore)"
                    } else {
                        "dry-run(remove)"
                    };
                    details.push(format!("{hook_name}={action}"));
                    continue;
                }
                fs::remove_file(&hook_path).map_err(|e| {
                    fail(
                        format!(
                            "HOOK_INSTALL_FAIL: failed removing {}: {e}",
                            hook_path.display()
                        ),
                        1,
                    )
                })?;
                if user_backup.is_file() {
                    fs::rename(&user_backup, &hook_path).map_err(|e| {
                        fail(
                            format!(
                                "HOOK_INSTALL_FAIL: failed restoring {} -> {}: {e}",
                                user_backup.display(),
                                hook_path.display()
                            ),
                            1,
                        )
                    })?;
                    details.push(format!("{hook_name}=restored(.b3-user)"));
                } else {
                    details.push(format!("{hook_name}=removed"));
                }
            } else {
                details.push(format!("{hook_name}=skipped(unmanaged)"));
            }
        } else if user_backup.is_file() {
            if dry_run {
                details.push(format!("{hook_name}=dry-run(restore)"));
            } else {
                fs::rename(&user_backup, &hook_path).map_err(|e| {
                    fail(
                        format!(
                            "HOOK_INSTALL_FAIL: failed restoring {} -> {}: {e}",
                            user_backup.display(),
                            hook_path.display()
                        ),
                        1,
                    )
                })?;
                details.push(format!("{hook_name}=restored(.b3-user)"));
            }
        } else {
            details.push(format!("{hook_name}=absent"));
        }
    }

    Ok(format!(
        "git (project): {} ({})",
        details.join(", "),
        hooks_dir.display()
    ))
}

fn verify_git_hooks(repo_root: Option<&Path>) -> Result<(String, bool), B3Error> {
    let root = resolve_project_root_dir(repo_root)?;
    let hooks_dir = resolve_git_hooks_dir(&root)?;
    if is_reparse_or_symlink(&hooks_dir) {
        return Ok((
            format!(
                "VERIFY_ERROR: git (project) hooks dir is a symlink/reparse point: {}",
                hooks_dir.display()
            ),
            false,
        ));
    }

    let mut errors = Vec::new();
    for &hook_name in GIT_HOOK_NAMES {
        let hook_path = hooks_dir.join(hook_name);
        if is_reparse_or_symlink(&hook_path) {
            errors.push(format!("{hook_name} is a symlink/reparse point"));
            continue;
        }
        if !hook_path.is_file() {
            errors.push(format!("{hook_name} missing"));
            continue;
        }
        let content = fs::read_to_string(&hook_path).unwrap_or_default();
        if !is_b3_git_shim(&content) {
            errors.push(format!("{hook_name} not B3-managed"));
            continue;
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if let Ok(meta) = fs::metadata(&hook_path) {
                if (meta.permissions().mode() & 0o111) == 0 {
                    errors.push(format!("{hook_name} not executable"));
                }
            }
        }
    }

    if errors.is_empty() {
        Ok((
            format!("VERIFY_OK: git (project) ({})", hooks_dir.display()),
            true,
        ))
    } else {
        Ok((
            format!(
                "VERIFY_MISSING: git (project) [{}] ({})",
                errors.join(", "),
                hooks_dir.display()
            ),
            false,
        ))
    }
}

/// Installs B3 native guard hooks for `host` and `scope`.
pub fn install_hooks(
    host: HookHostTarget,
    scope: HookScope,
    repo_root: Option<&Path>,
    user_home: Option<&Path>,
    b3_bin: Option<&str>,
    dry_run: bool,
    force: bool,
) -> Result<(String, i32), B3Error> {
    if host == HookHostTarget::Git && scope == HookScope::Global {
        return Err(fail(
            "HOOK_INSTALL_FAIL: git hooks are project-scope only (global scope is not supported)",
            1,
        ));
    }

    let home = resolve_user_home_dir(user_home);
    let bin = resolve_b3_bin_str(b3_bin)?;
    let mut lines = Vec::new();

    match host {
        HookHostTarget::Cursor => {
            lines.push(install_json_host(
                JsonHost::Cursor,
                scope,
                repo_root,
                &home,
                &bin,
                dry_run,
            )?);
        }
        HookHostTarget::Claude => {
            lines.push(install_json_host(
                JsonHost::Claude,
                scope,
                repo_root,
                &home,
                &bin,
                dry_run,
            )?);
        }
        HookHostTarget::Codex => {
            lines.push(install_json_host(
                JsonHost::Codex,
                scope,
                repo_root,
                &home,
                &bin,
                dry_run,
            )?);
        }
        HookHostTarget::Antigravity => {
            lines.push(install_json_host(
                JsonHost::Antigravity,
                scope,
                repo_root,
                &home,
                &bin,
                dry_run,
            )?);
        }
        HookHostTarget::Git => {
            lines.push(install_git_hooks(repo_root, &bin, dry_run, force)?);
        }
        HookHostTarget::All => {
            for jh in [
                JsonHost::Cursor,
                JsonHost::Claude,
                JsonHost::Codex,
                JsonHost::Antigravity,
            ] {
                lines.push(install_json_host(
                    jh, scope, repo_root, &home, &bin, dry_run,
                )?);
            }
            if scope == HookScope::Project {
                lines.push(install_git_hooks(repo_root, &bin, dry_run, force)?);
            } else {
                lines.push("git (global): skipped (project-scope only)".to_string());
            }
        }
    }

    Ok((lines.join("\n"), 0))
}

/// Uninstalls B3-managed hooks for `host` and `scope` while preserving user hooks and keys.
pub fn uninstall_hooks(
    host: HookHostTarget,
    scope: HookScope,
    repo_root: Option<&Path>,
    user_home: Option<&Path>,
    dry_run: bool,
) -> Result<(String, i32), B3Error> {
    if host == HookHostTarget::Git && scope == HookScope::Global {
        return Err(fail(
            "HOOK_INSTALL_FAIL: git hooks are project-scope only (global scope is not supported)",
            1,
        ));
    }

    let home = resolve_user_home_dir(user_home);
    let mut lines = Vec::new();

    match host {
        HookHostTarget::Cursor => {
            lines.push(uninstall_json_host(
                JsonHost::Cursor,
                scope,
                repo_root,
                &home,
                dry_run,
            )?);
        }
        HookHostTarget::Claude => {
            lines.push(uninstall_json_host(
                JsonHost::Claude,
                scope,
                repo_root,
                &home,
                dry_run,
            )?);
        }
        HookHostTarget::Codex => {
            lines.push(uninstall_json_host(
                JsonHost::Codex,
                scope,
                repo_root,
                &home,
                dry_run,
            )?);
        }
        HookHostTarget::Antigravity => {
            lines.push(uninstall_json_host(
                JsonHost::Antigravity,
                scope,
                repo_root,
                &home,
                dry_run,
            )?);
        }
        HookHostTarget::Git => {
            lines.push(uninstall_git_hooks(repo_root, dry_run)?);
        }
        HookHostTarget::All => {
            for jh in [
                JsonHost::Cursor,
                JsonHost::Claude,
                JsonHost::Codex,
                JsonHost::Antigravity,
            ] {
                lines.push(uninstall_json_host(jh, scope, repo_root, &home, dry_run)?);
            }
            if scope == HookScope::Project {
                lines.push(uninstall_git_hooks(repo_root, dry_run)?);
            } else {
                lines.push("git (global): skipped (project-scope only)".to_string());
            }
        }
    }

    Ok((lines.join("\n"), 0))
}

/// Verifies that B3 native guard hooks are installed and valid for `host` and `scope`.
pub fn verify_hooks(
    host: HookHostTarget,
    scope: HookScope,
    repo_root: Option<&Path>,
    user_home: Option<&Path>,
) -> Result<(String, i32), B3Error> {
    if host == HookHostTarget::Git && scope == HookScope::Global {
        return Err(fail(
            "HOOK_INSTALL_FAIL: git hooks are project-scope only (global scope is not supported)",
            1,
        ));
    }

    let home = resolve_user_home_dir(user_home);
    let mut lines = Vec::new();
    let mut all_ok = true;

    match host {
        HookHostTarget::Cursor => {
            let (msg, ok) = verify_json_host(JsonHost::Cursor, scope, repo_root, &home)?;
            all_ok &= ok;
            lines.push(msg);
        }
        HookHostTarget::Claude => {
            let (msg, ok) = verify_json_host(JsonHost::Claude, scope, repo_root, &home)?;
            all_ok &= ok;
            lines.push(msg);
        }
        HookHostTarget::Codex => {
            let (msg, ok) = verify_json_host(JsonHost::Codex, scope, repo_root, &home)?;
            all_ok &= ok;
            lines.push(msg);
        }
        HookHostTarget::Antigravity => {
            let (msg, ok) = verify_json_host(JsonHost::Antigravity, scope, repo_root, &home)?;
            all_ok &= ok;
            lines.push(msg);
        }
        HookHostTarget::Git => {
            let (msg, ok) = verify_git_hooks(repo_root)?;
            all_ok &= ok;
            lines.push(msg);
        }
        HookHostTarget::All => {
            for jh in [
                JsonHost::Cursor,
                JsonHost::Claude,
                JsonHost::Codex,
                JsonHost::Antigravity,
            ] {
                let (msg, ok) = verify_json_host(jh, scope, repo_root, &home)?;
                all_ok &= ok;
                lines.push(msg);
            }
            if scope == HookScope::Project {
                let (msg, ok) = verify_git_hooks(repo_root)?;
                all_ok &= ok;
                lines.push(msg);
            } else {
                lines.push("git (global): skipped (project-scope only)".to_string());
            }
        }
    }

    Ok((lines.join("\n"), if all_ok { 0 } else { 1 }))
}

/// Reports effective hook configuration and installation status across project and global scopes.
pub fn status_hooks(
    repo_root: Option<&Path>,
    user_home: Option<&Path>,
) -> Result<(String, i32), B3Error> {
    let home = resolve_user_home_dir(user_home);
    let resolved_project = match repo_root {
        Some(p) if !p.as_os_str().is_empty() => Some(resolve_project_root_dir(Some(p))?),
        _ => std::env::current_dir()
            .ok()
            .map(|p| PathBuf::from(normalize_abs_path_str(&p))),
    };

    let project_pref = resolved_project
        .as_deref()
        .map(default_project_preferences_path);
    let global_pref = default_global_preferences_path(Some(&home));
    let (cfg, warnings) = resolve_hook_config(project_pref.as_deref(), Some(&global_pref), None);

    let mut lines = vec![format!(
        "HOOK_CONFIG: enabled={} mode={}",
        cfg.enabled,
        cfg.mode.as_str()
    )];
    for w in warnings {
        lines.push(w);
    }

    if let Some(ref proj) = resolved_project {
        for jh in [
            JsonHost::Cursor,
            JsonHost::Claude,
            JsonHost::Codex,
            JsonHost::Antigravity,
        ] {
            let (msg, _) = verify_json_host(jh, HookScope::Project, Some(proj), &home)?;
            lines.push(msg);
        }
        match verify_git_hooks(Some(proj)) {
            Ok((msg, _)) => lines.push(msg),
            Err(e) => lines.push(format!("VERIFY_SKIP: git (project) ({})", e.message)),
        }
    }

    for jh in [
        JsonHost::Cursor,
        JsonHost::Claude,
        JsonHost::Codex,
        JsonHost::Antigravity,
    ] {
        let (msg, _) = verify_json_host(jh, HookScope::Global, None, &home)?;
        lines.push(msg);
    }

    Ok((lines.join("\n"), 0))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fs::next_tmp_suffix;

    fn lock_hook_env() -> std::sync::MutexGuard<'static, ()> {
        crate::hook::HOOK_ENV_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner())
    }

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("b3_hook_inst_{name}_{}", next_tmp_suffix()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn init_git_repo(dir: &Path) {
        let no_env: [(&str, &str); 0] = [];
        assert_eq!(run_git(dir, &["init"], &no_env, None).unwrap().exit_code, 0);
    }

    #[test]
    fn json_hosts_preserve_existing_keys_and_uninstall_cleanly() {
        let proj = temp_dir("json_proj");
        let home = temp_dir("json_home");

        // Pre-populate Claude settings.json with user key & user hook
        let claude_dir = proj.join(".claude");
        fs::create_dir_all(&claude_dir).unwrap();
        let claude_path = claude_dir.join("settings.json");
        let existing_claude = r#"{
  "model": "claude-sonnet",
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "echo user-hook"
          }
        ]
      }
    ]
  }
}
"#;
        fs::write(&claude_path, existing_claude).unwrap();

        let bin_with_spaces = if cfg!(windows) {
            r"C:\Program Files\B3 Tools\b3.exe"
        } else {
            "/opt/B3 Tools/José/b3"
        };

        // Install Claude + Cursor + Codex + Antigravity
        for host in [
            HookHostTarget::Cursor,
            HookHostTarget::Claude,
            HookHostTarget::Codex,
            HookHostTarget::Antigravity,
        ] {
            let (_, code) = install_hooks(
                host,
                HookScope::Project,
                Some(&proj),
                Some(&home),
                Some(bin_with_spaces),
                false,
                false,
            )
            .unwrap();
            assert_eq!(code, 0);
            let (_, vcode) =
                verify_hooks(host, HookScope::Project, Some(&proj), Some(&home)).unwrap();
            assert_eq!(vcode, 0, "verify failed for {}", host.as_str());
        }

        // Verify .b3-backup was created for modified Claude settings.json
        let claude_backup = backup_path_for(&claude_path);
        assert!(claude_backup.is_file());
        assert_eq!(fs::read_to_string(&claude_backup).unwrap(), existing_claude);

        // Idempotent second install does not duplicate entries
        let (msg2, _) = install_hooks(
            HookHostTarget::Claude,
            HookScope::Project,
            Some(&proj),
            Some(&home),
            Some(bin_with_spaces),
            false,
            false,
        )
        .unwrap();
        assert!(msg2.contains("unchanged"), "{msg2}");

        let claude_json = parse_json(&fs::read_to_string(&claude_path).unwrap()).unwrap();
        assert_eq!(
            claude_json.get("model").and_then(JsonValue::as_str),
            Some("claude-sonnet")
        );
        let pre_arr = claude_json
            .get("hooks")
            .and_then(|h| h.get("PreToolUse"))
            .and_then(JsonValue::as_array)
            .unwrap();
        assert_eq!(pre_arr.len(), 2);

        // Codex root-level and Antigravity b3-native-guard namespace
        let codex_json =
            parse_json(&fs::read_to_string(proj.join(".codex").join("hooks.json")).unwrap())
                .unwrap();
        assert!(codex_json.get("PreToolUse").is_some());
        assert!(codex_json.get("PostToolUse").is_some());
        assert!(codex_json.get("Stop").is_some());

        let agy_json =
            parse_json(&fs::read_to_string(proj.join(".agents").join("hooks.json")).unwrap())
                .unwrap();
        assert!(agy_json.get("b3-native-guard").is_some());

        // Global Antigravity path uses ~/.gemini/config/hooks.json
        let (_, gcode) = install_hooks(
            HookHostTarget::Antigravity,
            HookScope::Global,
            None,
            Some(&home),
            Some("b3"),
            false,
            false,
        )
        .unwrap();
        assert_eq!(gcode, 0);
        assert!(home
            .join(".gemini")
            .join("config")
            .join("hooks.json")
            .is_file());

        // Uninstall Claude removes only B3 hooks, keeps user hook and model key
        let (_, ucode) = uninstall_hooks(
            HookHostTarget::Claude,
            HookScope::Project,
            Some(&proj),
            Some(&home),
            false,
        )
        .unwrap();
        assert_eq!(ucode, 0);
        let (_, v_after) = verify_hooks(
            HookHostTarget::Claude,
            HookScope::Project,
            Some(&proj),
            Some(&home),
        )
        .unwrap();
        assert_eq!(v_after, 1);

        let claude_after = parse_json(&fs::read_to_string(&claude_path).unwrap()).unwrap();
        assert_eq!(
            claude_after.get("model").and_then(JsonValue::as_str),
            Some("claude-sonnet")
        );
        let pre_after = claude_after
            .get("hooks")
            .and_then(|h| h.get("PreToolUse"))
            .and_then(JsonValue::as_array)
            .unwrap();
        assert_eq!(pre_after.len(), 1);
        assert_eq!(
            pre_after[0].get("hooks").unwrap().as_array().unwrap()[0]
                .get("command")
                .and_then(JsonValue::as_str),
            Some("echo user-hook")
        );

        let _ = fs::remove_dir_all(&proj);
        let _ = fs::remove_dir_all(&home);
    }

    #[test]
    fn git_hooks_reject_global_chain_existing_user_hook_and_respect_hookspath() {
        let _lock = lock_hook_env();
        let repo = temp_dir("git_hooks");
        let home = temp_dir("git_home");
        init_git_repo(&repo);

        // Global scope for git must fail cleanly
        assert!(install_hooks(
            HookHostTarget::Git,
            HookScope::Global,
            Some(&repo),
            Some(&home),
            Some("b3"),
            false,
            false,
        )
        .is_err());

        // Configure relative core.hooksPath
        let no_env: [(&str, &str); 0] = [];
        assert_eq!(
            run_git(
                &repo,
                &["config", "core.hooksPath", ".githooks"],
                &no_env,
                None
            )
            .unwrap()
            .exit_code,
            0
        );
        let hooks_dir = repo.join(".githooks");
        fs::create_dir_all(&hooks_dir).unwrap();
        let user_precommit = "#!/bin/sh\necho user pre-commit\n";
        fs::write(hooks_dir.join("pre-commit"), user_precommit).unwrap();

        let (_, code) = install_hooks(
            HookHostTarget::Git,
            HookScope::Project,
            Some(&repo),
            Some(&home),
            Some("b3"),
            false,
            false,
        )
        .unwrap();
        assert_eq!(code, 0);

        let (_, vcode) = verify_hooks(
            HookHostTarget::Git,
            HookScope::Project,
            Some(&repo),
            Some(&home),
        )
        .unwrap();
        assert_eq!(vcode, 0);

        // User hook backed up and chained in LF shim
        assert_eq!(
            fs::read_to_string(hooks_dir.join("pre-commit.b3-user")).unwrap(),
            user_precommit
        );
        let shim = fs::read_to_string(hooks_dir.join("pre-commit")).unwrap();
        assert!(!shim.contains('\r'));
        assert!(shim.contains(GIT_HOOK_MARKER));
        assert!(shim.contains("B3_HOOK_ACTIVE"));
        assert!(shim.contains("pre-commit.b3-user"));

        // Conflicting user hook without --force fails
        fs::write(hooks_dir.join("pre-commit"), "#!/bin/sh\necho different\n").unwrap();
        assert!(install_hooks(
            HookHostTarget::Git,
            HookScope::Project,
            Some(&repo),
            Some(&home),
            Some("b3"),
            false,
            false,
        )
        .is_err());

        // With --force succeeds
        assert!(install_hooks(
            HookHostTarget::Git,
            HookScope::Project,
            Some(&repo),
            Some(&home),
            Some("b3"),
            false,
            true,
        )
        .is_ok());

        // Uninstall restores .b3-user back to pre-commit
        let (_, ucode) = uninstall_hooks(
            HookHostTarget::Git,
            HookScope::Project,
            Some(&repo),
            Some(&home),
            false,
        )
        .unwrap();
        assert_eq!(ucode, 0);
        assert!(!hooks_dir.join("pre-commit.b3-user").exists());
        assert_eq!(
            fs::read_to_string(hooks_dir.join("pre-commit")).unwrap(),
            "#!/bin/sh\necho different\n"
        );
        assert!(!hooks_dir.join("pre-push").exists());

        // status_hooks succeeds
        let (st_out, st_code) = status_hooks(Some(&repo), Some(&home)).unwrap();
        assert_eq!(st_code, 0);
        assert!(st_out.contains("HOOK_CONFIG:"), "{st_out}");

        let _ = fs::remove_dir_all(&repo);
        let _ = fs::remove_dir_all(&home);
    }

    #[test]
    fn all_target_dry_run_and_worktree_git_common_dir() {
        let _lock = lock_hook_env();
        let base = temp_dir("all_wt_José");
        let main_repo = base.join("main repo");
        let wt_repo = base.join("wt repo");
        let home = base.join("user home");
        fs::create_dir_all(&main_repo).unwrap();
        fs::create_dir_all(&home).unwrap();
        init_git_repo(&main_repo);

        let no_env: [(&str, &str); 0] = [];
        assert_eq!(
            run_git(
                &main_repo,
                &["config", "user.email", "t@example.com"],
                &no_env,
                None
            )
            .unwrap()
            .exit_code,
            0
        );
        assert_eq!(
            run_git(&main_repo, &["config", "user.name", "Test"], &no_env, None)
                .unwrap()
                .exit_code,
            0
        );
        fs::write(main_repo.join("README.md"), "hello\n").unwrap();
        assert_eq!(
            run_git(&main_repo, &["add", "README.md"], &no_env, None)
                .unwrap()
                .exit_code,
            0
        );
        assert_eq!(
            run_git(&main_repo, &["commit", "-m", "init"], &no_env, None)
                .unwrap()
                .exit_code,
            0
        );
        assert_eq!(
            run_git(
                &main_repo,
                &["worktree", "add", "-b", "feat", &wt_repo.to_string_lossy()],
                &no_env,
                None
            )
            .unwrap()
            .exit_code,
            0
        );

        // dry_run creates no files
        let (dry_msg, dry_code) = install_hooks(
            HookHostTarget::All,
            HookScope::Project,
            Some(&wt_repo),
            Some(&home),
            Some("b3"),
            true,
            false,
        )
        .unwrap();
        assert_eq!(dry_code, 0);
        assert!(dry_msg.contains("dry-run"), "{dry_msg}");
        assert!(!wt_repo.join(".cursor").exists());
        assert!(!main_repo
            .join(".git")
            .join("hooks")
            .join("pre-commit")
            .exists());

        // Real install from worktree installs git hooks into common .git/hooks
        let (_, code) = install_hooks(
            HookHostTarget::All,
            HookScope::Project,
            Some(&wt_repo),
            Some(&home),
            Some("b3"),
            false,
            false,
        )
        .unwrap();
        assert_eq!(code, 0);
        assert!(main_repo
            .join(".git")
            .join("hooks")
            .join("pre-commit")
            .is_file());
        assert!(main_repo
            .join(".git")
            .join("hooks")
            .join("pre-push")
            .is_file());
        assert!(main_repo
            .join(".git")
            .join("hooks")
            .join("pre-merge-commit")
            .is_file());
        assert_eq!(
            verify_hooks(
                HookHostTarget::All,
                HookScope::Project,
                Some(&wt_repo),
                Some(&home)
            )
            .unwrap()
            .1,
            0
        );

        // All + Global skips git cleanly and installs 4 JSON hosts
        let (g_msg, g_code) = install_hooks(
            HookHostTarget::All,
            HookScope::Global,
            None,
            Some(&home),
            Some("b3"),
            false,
            false,
        )
        .unwrap();
        assert_eq!(g_code, 0);
        assert!(g_msg.contains("skipped (project-scope only)"), "{g_msg}");
        assert_eq!(
            verify_hooks(HookHostTarget::All, HookScope::Global, None, Some(&home))
                .unwrap()
                .1,
            0
        );

        let _ = fs::remove_dir_all(&base);
    }
}
