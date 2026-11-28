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
use crate::hook::norm_cmp_path;
use crate::json::{parse_json, JsonValue};

const GIT_HOOK_MARKER: &str = "# b3-native-guard-hook";
const GIT_HOOK_NAMES: &[&str] = &["pre-commit", "pre-push", "pre-merge-commit"];
const ALL_JSON_HOSTS: &[JsonHost] = &[
    JsonHost::Cursor,
    JsonHost::Claude,
    JsonHost::Codex,
    JsonHost::Antigravity,
];

fn err(msg: impl Into<String>) -> B3Error {
    fail(msg, 1)
}

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
            _ => Err(err(format!(
                "HOOK_INSTALL_FAIL: unsupported host target '{raw}'; expected cursor, claude, codex, antigravity, git, or all"
            ))),
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
            _ => Err(err(format!(
                "HOOK_INSTALL_FAIL: invalid scope '{raw}'; expected project or global"
            ))),
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
enum HookEntryShape {
    CursorFlat,
    TypedFlat,
    Grouped,
}

#[derive(Debug, Clone, Copy)]
struct EventSpec {
    name: &'static str,
    matcher: Option<&'static str>,
    shape: HookEntryShape,
}

const fn ev(name: &'static str, matcher: Option<&'static str>, shape: HookEntryShape) -> EventSpec {
    EventSpec {
        name,
        matcher,
        shape,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum JsonHost {
    Cursor,
    Claude,
    Codex,
    Antigravity,
}

fn json_hosts_for_target(target: HookHostTarget) -> &'static [JsonHost] {
    match target {
        HookHostTarget::Cursor => &[JsonHost::Cursor],
        HookHostTarget::Claude => &[JsonHost::Claude],
        HookHostTarget::Codex => &[JsonHost::Codex],
        HookHostTarget::Antigravity => &[JsonHost::Antigravity],
        HookHostTarget::Git => &[],
        HookHostTarget::All => ALL_JSON_HOSTS,
    }
}

fn includes_git(target: HookHostTarget) -> bool {
    matches!(target, HookHostTarget::Git | HookHostTarget::All)
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

    fn container_key(self) -> &'static str {
        if self == Self::Antigravity {
            "b3-native-guard"
        } else {
            "hooks"
        }
    }

    fn config_path(
        self,
        scope: HookScope,
        repo_root: Option<&Path>,
        user_home: &Path,
    ) -> Result<PathBuf, B3Error> {
        let base = scope_base_dir(scope, repo_root, user_home)?;
        Ok(match (self, scope) {
            (Self::Cursor, _) => base.join(".cursor/hooks.json"),
            (Self::Claude, _) => base.join(".claude/settings.json"),
            (Self::Codex, _) => base.join(".codex/hooks.json"),
            (Self::Antigravity, HookScope::Project) => base.join(".agents/hooks.json"),
            (Self::Antigravity, HookScope::Global) => base.join(".gemini/config/hooks.json"),
        })
    }

    fn event_specs(self) -> &'static [EventSpec] {
        const CURSOR: &[EventSpec] = &[
            ev("preToolUse", None, HookEntryShape::CursorFlat),
            ev("beforeShellExecution", None, HookEntryShape::CursorFlat),
            ev("afterFileEdit", None, HookEntryShape::CursorFlat),
            ev("subagentStop", None, HookEntryShape::CursorFlat),
            ev("stop", None, HookEntryShape::CursorFlat),
        ];
        const CLAUDE: &[EventSpec] = &[
            ev(
                "PreToolUse",
                Some("Edit|Write|MultiEdit|NotebookEdit|Bash"),
                HookEntryShape::Grouped,
            ),
            ev(
                "PostToolUse",
                Some("Edit|Write|MultiEdit|NotebookEdit"),
                HookEntryShape::Grouped,
            ),
            ev("SubagentStop", None, HookEntryShape::Grouped),
            ev("Stop", None, HookEntryShape::Grouped),
        ];
        const CODEX: &[EventSpec] = &[
            ev(
                "PreToolUse",
                Some("apply_patch|Write|Edit|Bash|shell"),
                HookEntryShape::Grouped,
            ),
            ev(
                "PostToolUse",
                Some("apply_patch|Write|Edit"),
                HookEntryShape::Grouped,
            ),
            ev("Stop", None, HookEntryShape::Grouped),
        ];
        const AGY: &[EventSpec] = &[
            ev("PreToolUse", Some("write_file|edit_file|write_to_file|replace_file_content|multi_replace_file_content|run_command"), HookEntryShape::Grouped),
            ev("PostToolUse", Some("write_file|edit_file|write_to_file|replace_file_content|multi_replace_file_content"), HookEntryShape::Grouped),
            ev("Stop", None, HookEntryShape::TypedFlat),
        ];
        match self {
            Self::Cursor => CURSOR,
            Self::Claude => CLAUDE,
            Self::Codex => CODEX,
            Self::Antigravity => AGY,
        }
    }
}

fn scope_base_dir(
    scope: HookScope,
    repo_root: Option<&Path>,
    user_home: &Path,
) -> Result<PathBuf, B3Error> {
    match scope {
        HookScope::Project => resolve_project_root_dir(repo_root),
        HookScope::Global => Ok(user_home.to_path_buf()),
    }
}

fn resolve_project_root_dir(repo_root: Option<&Path>) -> Result<PathBuf, B3Error> {
    let raw = match repo_root {
        Some(p) if !p.as_os_str().is_empty() => p.to_path_buf(),
        _ => std::env::current_dir()
            .map_err(|e| err(format!("HOOK_INSTALL_FAIL: cannot resolve cwd: {e}")))?,
    };
    let s = raw.to_string_lossy();
    if has_control_chars(&s) {
        return Err(err(
            "HOOK_INSTALL_FAIL: control characters rejected in repo_root",
        ));
    }
    let abs = if raw.is_absolute() {
        resolve_unresolved_path(&raw, ".")
    } else {
        let cwd = std::env::current_dir()
            .map_err(|e| err(format!("HOOK_INSTALL_FAIL: cannot resolve cwd: {e}")))?;
        resolve_unresolved_path(&cwd, &s)
    };
    Ok(PathBuf::from(normalize_abs_path_str(&abs)))
}

fn resolve_b3_bin_str(explicit: Option<&str>) -> Result<String, B3Error> {
    if let Some(raw) = explicit.map(str::trim).filter(|s| !s.is_empty()) {
        if has_control_chars(raw) {
            return Err(err(
                "HOOK_INSTALL_FAIL: control characters rejected in b3_bin",
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
    let norm = if cfg!(windows) && (b3_bin.contains('\\') || b3_bin.contains('/')) {
        b3_bin.replace('\\', "/")
    } else {
        b3_bin.to_string()
    };
    let needs_quotes = (cfg!(windows) && norm.contains('/'))
        || norm.chars().any(|c| {
            c.is_whitespace()
                || matches!(
                    c,
                    '"' | '\'' | '$' | '`' | '&' | '|' | ';' | '(' | ')' | '<' | '>' | '\\'
                )
                || !c.is_ascii()
        });
    if !needs_quotes {
        return norm;
    }
    let mut out = String::with_capacity(norm.len() + 4);
    out.push('"');
    for ch in norm.chars() {
        if matches!(ch, '"' | '\\' | '$' | '`') {
            out.push('\\');
        }
        out.push(ch);
    }
    out.push('"');
    out
}

fn sh_single_quote(raw: &str) -> String {
    format!("'{}'", raw.replace('\'', "'\\''"))
}

fn is_b3_managed_command(cmd: &str) -> bool {
    let trimmed = cmd.trim();
    if trimmed.is_empty() {
        return false;
    }
    if trimmed.contains("b3 hook run") {
        return true;
    }
    let (tok, rest) = if let Some(after_q) = trimmed
        .strip_prefix('"')
        .or_else(|| trimmed.strip_prefix('\''))
    {
        let q = trimmed.as_bytes()[0] as char;
        let mut esc = false;
        let mut end = None;
        for (idx, ch) in after_q.char_indices() {
            if esc {
                esc = false;
            } else if q == '"' && ch == '\\' {
                esc = true;
            } else if ch == q {
                end = Some(idx);
                break;
            }
        }
        let i = end.unwrap_or(after_q.len());
        (&after_q[..i], after_q.get(i + 1..).unwrap_or(""))
    } else {
        let i = trimmed.find(char::is_whitespace).unwrap_or(trimmed.len());
        (&trimmed[..i], &trimmed[i..])
    };
    let base = tok
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or("")
        .to_ascii_lowercase();
    let tail = rest.trim_start();
    (base == "b3" || base == "b3.exe") && (tail == "hook run" || tail.starts_with("hook run "))
}

fn backup_path_for(dest: &Path) -> PathBuf {
    let mut os: OsString = dest.as_os_str().to_os_string();
    os.push(".b3-backup");
    PathBuf::from(os)
}

fn write_raw_bytes_atomic(dest: &Path, bytes: &[u8]) -> Result<(), B3Error> {
    assert_regular_file_or_missing(dest, "backup file")?;
    if let Some(parent) = dest
        .parent()
        .filter(|p| !p.as_os_str().is_empty() && !p.exists())
    {
        fs::create_dir_all(parent).map_err(|e| {
            err(format!(
                "HOOK_INSTALL_FAIL: failed creating directory {}: {e}",
                parent.display()
            ))
        })?;
    }
    let name = dest
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or_else(|| err("HOOK_INSTALL_FAIL: invalid backup path"))?;
    let tmp = dest.with_file_name(format!("{name}.tmp.{}", next_tmp_suffix()));
    let mut f = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&tmp)
        .map_err(|e| {
            err(format!(
                "HOOK_INSTALL_FAIL: failed creating temp backup: {e}"
            ))
        })?;
    if let Err(e) = f.write_all(bytes).and_then(|_| f.flush()) {
        drop(f);
        let _ = fs::remove_file(&tmp);
        return Err(err(format!(
            "HOOK_INSTALL_FAIL: failed writing backup {}: {e}",
            dest.display()
        )));
    }
    drop(f);
    fs::rename(&tmp, dest).map_err(|e| {
        let _ = fs::remove_file(&tmp);
        err(format!(
            "HOOK_INSTALL_FAIL: failed committing backup {}: {e}",
            dest.display()
        ))
    })
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
    match entries.iter_mut().find(|(k, _)| k == key) {
        None => Ok(Vec::new()),
        Some((_, JsonValue::Object(inner))) => Ok(std::mem::take(inner)),
        Some(_) => Err(err(format!(
            "HOOK_INSTALL_FAIL: expected JSON object at key '{key}'"
        ))),
    }
}

fn take_or_init_array(
    entries: &mut [(String, JsonValue)],
    key: &str,
) -> Result<Vec<JsonValue>, B3Error> {
    match entries.iter_mut().find(|(k, _)| k == key) {
        None => Ok(Vec::new()),
        Some((_, JsonValue::Array(arr))) => Ok(std::mem::take(arr)),
        Some(_) => Err(err(format!(
            "HOOK_INSTALL_FAIL: expected JSON array at key '{key}'"
        ))),
    }
}

fn make_hook_entry(shape: HookEntryShape, matcher: Option<&str>, command: &str) -> JsonValue {
    match shape {
        HookEntryShape::CursorFlat => {
            JsonValue::obj(vec![("command".into(), JsonValue::str(command))])
        }
        HookEntryShape::TypedFlat => JsonValue::obj(vec![
            ("type".into(), JsonValue::str("command")),
            ("command".into(), JsonValue::str(command)),
        ]),
        HookEntryShape::Grouped => {
            let inner = make_hook_entry(HookEntryShape::TypedFlat, None, command);
            let mut group = Vec::new();
            if let Some(m) = matcher {
                group.push(("matcher".into(), JsonValue::str(m)));
            }
            group.push(("hooks".into(), JsonValue::Array(vec![inner])));
            JsonValue::Object(group)
        }
    }
}

fn entry_matches_cmd(item: &JsonValue, shape: HookEntryShape, pred: impl Fn(&str) -> bool) -> bool {
    match shape {
        HookEntryShape::CursorFlat => {
            item.get("hooks").is_none()
                && item
                    .get("command")
                    .and_then(JsonValue::as_str)
                    .is_some_and(pred)
        }
        HookEntryShape::TypedFlat => {
            item.get("hooks").is_none()
                && item.get("type").and_then(JsonValue::as_str) == Some("command")
                && item
                    .get("command")
                    .and_then(JsonValue::as_str)
                    .is_some_and(pred)
        }
        HookEntryShape::Grouped => {
            item.get("hooks")
                .and_then(JsonValue::as_array)
                .is_some_and(|hs| {
                    hs.iter().any(|h| {
                        h.get("command")
                            .and_then(JsonValue::as_str)
                            .is_some_and(&pred)
                    })
                })
        }
    }
}

fn entry_has_exact_spec(item: &JsonValue, spec: EventSpec, expected_cmd: &str) -> bool {
    (spec.shape != HookEntryShape::Grouped
        || item.get("matcher").and_then(JsonValue::as_str) == spec.matcher)
        && entry_matches_cmd(item, spec.shape, |c| c == expected_cmd)
}

fn upsert_event_array(arr: &mut Vec<JsonValue>, spec: EventSpec, expected_cmd: &str) -> bool {
    if arr
        .iter()
        .any(|item| entry_has_exact_spec(item, spec, expected_cmd))
    {
        return false;
    }
    for item in arr.iter_mut() {
        if entry_matches_cmd(item, HookEntryShape::CursorFlat, is_b3_managed_command)
            || entry_matches_cmd(item, HookEntryShape::Grouped, is_b3_managed_command)
        {
            *item = make_hook_entry(spec.shape, spec.matcher, expected_cmd);
            return true;
        }
    }
    arr.push(make_hook_entry(spec.shape, spec.matcher, expected_cmd));
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
                let before = inner.len();
                inner.retain(|h| {
                    !h.get("command")
                        .and_then(JsonValue::as_str)
                        .is_some_and(is_b3_managed_command)
                });
                let diff = before - inner.len();
                removed += diff;
                if diff > 0 && inner.is_empty() {
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

fn remove_events_from_map(map_entries: &mut Vec<(String, JsonValue)>, events: &[&str]) -> usize {
    let mut removed = 0usize;
    for &ev_name in events {
        if let Some(pos) = map_entries.iter().position(|(k, _)| k == ev_name) {
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
        return Err(err("HOOK_INSTALL_FAIL: config root must be a JSON object"));
    };
    let mut changed = false;
    if host == JsonHost::Cursor && !root_entries.iter().any(|(k, _)| k == "version") {
        root_entries.insert(0, ("version".into(), JsonValue::num_u64(1)));
        changed = true;
    }

    let ckey = host.container_key();
    let mut container = take_or_init_object_entries(&mut root_entries, ckey)?;
    let bin = format_shell_bin_for_json(b3_bin);
    for &spec in host.event_specs() {
        let cmd = format!(
            "{bin} hook run --host {} --event {}",
            host.as_str(),
            spec.name
        );
        let mut arr = take_or_init_array(&mut container, spec.name)?;
        changed |= upsert_event_array(&mut arr, spec, &cmd);
        upsert_json_key(&mut container, spec.name, JsonValue::Array(arr));
    }
    upsert_json_key(&mut root_entries, ckey, JsonValue::Object(container));

    if host == JsonHost::Codex {
        let ev_names: Vec<&str> = host.event_specs().iter().map(|s| s.name).collect();
        changed |= remove_events_from_map(&mut root_entries, &ev_names) > 0;
    }
    Ok((JsonValue::Object(root_entries), changed))
}

fn apply_json_uninstall(host: JsonHost, root: &JsonValue) -> Result<(JsonValue, usize), B3Error> {
    let JsonValue::Object(mut root_entries) = root.clone() else {
        return Err(err("HOOK_INSTALL_FAIL: config root must be a JSON object"));
    };
    let ev_names: Vec<&str> = host.event_specs().iter().map(|s| s.name).collect();
    let ckey = host.container_key();
    let mut removed = 0usize;
    if let Some(pos) = root_entries.iter().position(|(k, _)| k == ckey) {
        if let JsonValue::Object(ref mut container) = root_entries[pos].1 {
            let r = remove_events_from_map(container, &ev_names);
            removed += r;
            if r > 0 && container.is_empty() && host != JsonHost::Cursor {
                root_entries.remove(pos);
            }
        }
    }
    if host == JsonHost::Codex {
        removed += remove_events_from_map(&mut root_entries, &ev_names);
    }
    Ok((JsonValue::Object(root_entries), removed))
}

fn verify_json_config_value(host: JsonHost, root: &JsonValue) -> Vec<String> {
    let container = root.get(host.container_key());
    host.event_specs()
        .iter()
        .filter(|spec| {
            !container
                .and_then(|c| c.get(spec.name))
                .and_then(JsonValue::as_array)
                .is_some_and(|arr| {
                    arr.iter()
                        .any(|i| entry_matches_cmd(i, spec.shape, is_b3_managed_command))
                })
        })
        .map(|spec| spec.name.to_string())
        .collect()
}

fn read_json_object(dest: &Path) -> Result<(Vec<u8>, JsonValue), B3Error> {
    let bytes = fs::read(dest).map_err(|e| {
        err(format!(
            "HOOK_INSTALL_FAIL: cannot read {}: {e}",
            dest.display()
        ))
    })?;
    let raw = std::str::from_utf8(&bytes).map_err(|_| {
        err(format!(
            "HOOK_INSTALL_FAIL: non-UTF-8 config at {}",
            dest.display()
        ))
    })?;
    let parsed = parse_json(raw).map_err(|e| {
        err(format!(
            "HOOK_INSTALL_FAIL: invalid JSON in {}: {e}",
            dest.display()
        ))
    })?;
    if !parsed.is_object() {
        return Err(err(format!(
            "HOOK_INSTALL_FAIL: expected JSON object in {}",
            dest.display()
        )));
    }
    Ok((bytes, parsed))
}

fn write_json_with_backup_rollback(
    dest: &Path,
    new_json: &JsonValue,
    existing_bytes: Option<&[u8]>,
) -> Result<(), B3Error> {
    let pretty = format!("{}\n", new_json.to_json_pretty());
    if let Some(orig) = existing_bytes {
        write_raw_bytes_atomic(&backup_path_for(dest), orig)?;
        if let Err(e) = write_atomic_lf(dest, &pretty) {
            let _ = write_raw_bytes_atomic(dest, orig);
            return Err(e);
        }
        Ok(())
    } else {
        write_atomic_lf(dest, &pretty)
    }
}

fn install_json_host(
    host: JsonHost,
    scope: HookScope,
    repo_root: Option<&Path>,
    user_home: &Path,
    b3_bin: &str,
    dry_run: bool,
) -> Result<String, B3Error> {
    let stop_at = scope_base_dir(scope, repo_root, user_home)?;
    let dest = host.config_path(scope, repo_root, user_home)?;
    assert_safe_config_ancestors(&dest, &stop_at)?;
    let (existing_bytes, current_val) = if dest.exists() {
        let (bytes, parsed) = read_json_object(&dest)?;
        (Some(bytes), parsed)
    } else {
        (None, JsonValue::Object(Vec::new()))
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
    let stop_at = scope_base_dir(scope, repo_root, user_home)?;
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
    let (orig_bytes, parsed) = read_json_object(&dest)?;
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
    let prefix = format!("{} ({})", host.as_str(), scope.as_str());
    if is_reparse_or_symlink(&dest) {
        return Ok((
            format!(
                "VERIFY_ERROR: {prefix} config is a symlink/reparse point: {}",
                dest.display()
            ),
            false,
        ));
    }
    if !dest.is_file() {
        return Ok((
            format!(
                "VERIFY_MISSING: {prefix} config not found: {}",
                dest.display()
            ),
            false,
        ));
    }
    let raw = match fs::read_to_string(&dest) {
        Ok(s) => s,
        Err(e) => {
            return Ok((
                format!("VERIFY_ERROR: {prefix} unreadable {}: {e}", dest.display()),
                false,
            ))
        }
    };
    let parsed = match parse_json(&raw) {
        Ok(v) if v.is_object() => v,
        Ok(_) => {
            return Ok((
                format!(
                    "VERIFY_ERROR: {prefix} config is not a JSON object: {}",
                    dest.display()
                ),
                false,
            ))
        }
        Err(e) => {
            return Ok((
                format!(
                    "VERIFY_ERROR: {prefix} invalid JSON {}: {e}",
                    dest.display()
                ),
                false,
            ))
        }
    };
    let missing = verify_json_config_value(host, &parsed);
    if missing.is_empty() {
        Ok((format!("VERIFY_OK: {prefix} ({})", dest.display()), true))
    } else {
        Ok((
            format!(
                "VERIFY_MISSING: {prefix} missing hooks [{}] in {}",
                missing.join(", "),
                dest.display()
            ),
            false,
        ))
    }
}

fn is_path_within_dir(candidate: &Path, parent: &Path) -> bool {
    let c = norm_cmp_path(candidate);
    let p = norm_cmp_path(parent);
    c == p || c.starts_with(&format!("{p}/"))
}

fn assert_no_reparse_ancestors_within(base: &Path, target: &Path) -> Result<(), B3Error> {
    let (base_norm, target_norm) = (norm_cmp_path(base), norm_cmp_path(target));
    let rel = if target_norm == base_norm {
        ""
    } else if let Some(rest) = target_norm.strip_prefix(&format!("{base_norm}/")) {
        rest
    } else {
        return Ok(());
    };
    let mut cur = base.to_path_buf();
    if is_reparse_or_symlink(&cur) {
        return Err(err(format!(
            "HOOK_INSTALL_FAIL: symlink/reparse point in repository path: {}",
            cur.display()
        )));
    }
    for seg in rel.split('/').filter(|s| !s.is_empty()) {
        cur.push(seg);
        if is_reparse_or_symlink(&cur) {
            return Err(err(format!(
                "HOOK_INSTALL_FAIL: symlink/reparse point in hooks ancestor path: {}",
                cur.display()
            )));
        }
    }
    Ok(())
}

fn resolve_git_hooks_dir(repo_root: &Path) -> Result<PathBuf, B3Error> {
    let no_env: [(&str, &str); 0] = [];
    let top_res = run_git(repo_root, &["rev-parse", "--show-toplevel"], &no_env, None)?;
    if top_res.exit_code != 0 {
        return Err(err(format!(
            "HOOK_INSTALL_FAIL: not a git repository: {}",
            repo_root.display()
        )));
    }
    let toplevel =
        resolve_unresolved_path(repo_root, String::from_utf8_lossy(&top_res.stdout).trim());
    let common_res = run_git(repo_root, &["rev-parse", "--git-common-dir"], &no_env, None)?;
    let common_raw = String::from_utf8_lossy(&common_res.stdout)
        .trim()
        .to_string();
    if common_res.exit_code != 0 || common_raw.is_empty() {
        return Err(err("HOOK_INSTALL_FAIL: failed to resolve git common dir"));
    }
    let common_dir = resolve_unresolved_path(repo_root, &common_raw);

    // Honor only repo-local core.hooksPath; never write into global/system core.hooksPath.
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
                resolve_unresolved_path(&toplevel, &hp)
            };
            if is_path_within_dir(&resolved, &toplevel) {
                assert_no_reparse_ancestors_within(&toplevel, &resolved)?;
            } else if is_path_within_dir(&resolved, &common_dir) {
                assert_no_reparse_ancestors_within(&common_dir, &resolved)?;
            } else {
                return Err(err(format!(
                    "HOOK_INSTALL_FAIL: local core.hooksPath escapes repository scope: {}",
                    resolved.display()
                )));
            }
            return Ok(PathBuf::from(normalize_abs_path_str(&resolved)));
        }
    }

    let default_hooks = common_dir.join("hooks");
    assert_no_reparse_ancestors_within(&common_dir, &default_hooks)?;
    Ok(PathBuf::from(normalize_abs_path_str(&default_hooks)))
}

fn build_git_hook_shim(hook_name: &str, b3_bin: &str, repo_root: &Path) -> String {
    let bin_sh = if cfg!(windows) && (b3_bin.contains('\\') || b3_bin.contains('/')) {
        b3_bin.replace('\\', "/")
    } else {
        b3_bin.to_string()
    };
    let root_sh = normalize_abs_path_str(repo_root).replace('\\', "/");
    format!(
        "#!/bin/sh\n{GIT_HOOK_MARKER} v2 ({hook_name})\n\
         B3_BIN={}\nDEFAULT_REPO_ROOT={}\n\
         REPO_ROOT=\"$(git rev-parse --show-toplevel 2>/dev/null || true)\"\n\
         [ -n \"$REPO_ROOT\" ] || REPO_ROOT=\"$DEFAULT_REPO_ROOT\"\n\
         HAS_STDIN=0\nSTDIN_DATA=\"\"\n\
         if [ ! -t 0 ]; then\n  HAS_STDIN=1\n  STDIN_DATA=\"$(cat)\"\nfi\n\
         run_with_stdin() {{\n\
           if [ \"$HAS_STDIN\" -eq 1 ]; then\n\
             if [ -n \"$STDIN_DATA\" ]; then\n      printf '%s\\n' \"$STDIN_DATA\" | \"$@\"\n    else\n      \"$@\" </dev/null\n    fi\n\
           else\n    \"$@\"\n  fi\n}}\n\
         if [ \"${{B3_HOOK_ACTIVE:-}}\" != \"1\" ] && [ \"${{B3_HOOK_ACTIVE:-}}\" != \"true\" ]; then\n\
           if [ \"$HAS_STDIN\" -eq 1 ]; then\n\
             run_with_stdin \"$B3_BIN\" hook run --host git --event {hook_name} --repo-root \"$REPO_ROOT\" -- \"$@\"\n\
           else\n\
             \"$B3_BIN\" hook run --host git --event {hook_name} --repo-root \"$REPO_ROOT\" -- \"$@\" </dev/null\n\
           fi\n  rc=$?\n  [ \"$rc\" -eq 0 ] || exit \"$rc\"\nfi\n\
         USER_HOOK=\"$(dirname \"$0\")/\"{}\n\
         if [ -x \"$USER_HOOK\" ]; then\n  run_with_stdin env B3_HOOK_ACTIVE=1 \"$USER_HOOK\" \"$@\"\n  exit $?\nfi\nexit 0\n",
        sh_single_quote(&bin_sh),
        sh_single_quote(&root_sh),
        sh_single_quote(&format!("{hook_name}.b3-user")),
    )
}

fn set_executable_if_unix(path: &Path) -> Result<(), B3Error> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o755)).map_err(|e| {
            err(format!(
                "HOOK_INSTALL_FAIL: failed setting 0o755 on {}: {e}",
                path.display()
            ))
        })?;
    }
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}

fn apply_permissions_opt(path: &Path, perms: Option<&fs::Permissions>) -> Result<(), B3Error> {
    if let Some(p) = perms {
        fs::set_permissions(path, p.clone()).map_err(|e| {
            err(format!(
                "HOOK_INSTALL_FAIL: failed setting permissions on {}: {e}",
                path.display()
            ))
        })?;
    }
    Ok(())
}

struct GitHookBackup {
    orig_bytes: Vec<u8>,
    orig_perms: Option<fs::Permissions>,
    prior_backup: Option<(Vec<u8>, Option<fs::Permissions>)>,
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
        let mut backup_plan: Option<GitHookBackup> = None;

        if hook_path.exists() {
            let orig_perms = fs::metadata(&hook_path).ok().map(|m| m.permissions());
            let existing_bytes = fs::read(&hook_path).map_err(|e| {
                err(format!(
                    "HOOK_INSTALL_FAIL: cannot read existing hook {}: {e}",
                    hook_path.display()
                ))
            })?;
            let existing_str = String::from_utf8_lossy(&existing_bytes);
            if existing_str.contains(GIT_HOOK_MARKER) {
                if existing_str == shim_text {
                    details.push(format!("{hook_name}=unchanged"));
                    continue;
                }
            } else {
                let prior_backup = if user_backup.exists() {
                    let prev_perms = fs::metadata(&user_backup).ok().map(|m| m.permissions());
                    let prev_bytes = fs::read(&user_backup).map_err(|e| {
                        err(format!(
                            "HOOK_INSTALL_FAIL: cannot read backup {}: {e}",
                            user_backup.display()
                        ))
                    })?;
                    if prev_bytes != existing_bytes && !force {
                        return Err(err(format!(
                            "HOOK_INSTALL_FAIL: existing user hook backup differs at {} (re-run with --force to replace)",
                            user_backup.display()
                        )));
                    }
                    Some((prev_bytes, prev_perms))
                } else {
                    None
                };
                backup_plan = Some(GitHookBackup {
                    orig_bytes: existing_bytes,
                    orig_perms,
                    prior_backup,
                });
            }
        }

        if dry_run {
            details.push(format!(
                "{hook_name}=dry-run({})",
                if backup_plan.is_some() {
                    "backup+install"
                } else {
                    "install"
                }
            ));
            continue;
        }

        if let Some(ref plan) = backup_plan {
            write_raw_bytes_atomic(&user_backup, &plan.orig_bytes)?;
            apply_permissions_opt(&user_backup, plan.orig_perms.as_ref())?;
        }
        if let Err(e) =
            write_atomic_lf(&hook_path, &shim_text).and_then(|_| set_executable_if_unix(&hook_path))
        {
            if let Some(ref plan) = backup_plan {
                let _ = write_raw_bytes_atomic(&hook_path, &plan.orig_bytes);
                let _ = apply_permissions_opt(&hook_path, plan.orig_perms.as_ref());
                match &plan.prior_backup {
                    Some((prev_bytes, prev_perms)) => {
                        let _ = write_raw_bytes_atomic(&user_backup, prev_bytes);
                        let _ = apply_permissions_opt(&user_backup, prev_perms.as_ref());
                    }
                    None => {
                        let _ = fs::remove_file(&user_backup);
                    }
                }
            }
            return Err(e);
        }
        details.push(if backup_plan.is_some() {
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

        let is_b3 = if hook_path.exists() {
            fs::read_to_string(&hook_path)
                .map_err(|e| {
                    err(format!(
                        "HOOK_INSTALL_FAIL: cannot read {}: {e}",
                        hook_path.display()
                    ))
                })?
                .contains(GIT_HOOK_MARKER)
        } else {
            false
        };

        if hook_path.exists() && !is_b3 {
            details.push(format!("{hook_name}=skipped(unmanaged)"));
        } else if is_b3 || user_backup.is_file() {
            if dry_run {
                let tag = match (is_b3, user_backup.is_file()) {
                    (true, true) => "dry-run(remove+restore)",
                    (true, false) => "dry-run(remove)",
                    (false, true) => "dry-run(restore)",
                    _ => unreachable!(),
                };
                details.push(format!("{hook_name}={tag}"));
                continue;
            }
            if is_b3 {
                fs::remove_file(&hook_path).map_err(|e| {
                    err(format!(
                        "HOOK_INSTALL_FAIL: failed removing {}: {e}",
                        hook_path.display()
                    ))
                })?;
            }
            if user_backup.is_file() {
                fs::rename(&user_backup, &hook_path).map_err(|e| {
                    err(format!(
                        "HOOK_INSTALL_FAIL: failed restoring {} -> {}: {e}",
                        user_backup.display(),
                        hook_path.display()
                    ))
                })?;
                details.push(format!("{hook_name}=restored(.b3-user)"));
            } else {
                details.push(format!("{hook_name}=removed"));
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
        } else if !hook_path.is_file() {
            errors.push(format!("{hook_name} missing"));
        } else if !fs::read_to_string(&hook_path)
            .unwrap_or_default()
            .contains(GIT_HOOK_MARKER)
        {
            errors.push(format!("{hook_name} not B3-managed"));
        } else {
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

fn reject_global_git(host: HookHostTarget, scope: HookScope) -> Result<(), B3Error> {
    if host == HookHostTarget::Git && scope == HookScope::Global {
        return Err(err(
            "HOOK_INSTALL_FAIL: git hooks are project-scope only (global scope is not supported)",
        ));
    }
    Ok(())
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
    reject_global_git(host, scope)?;
    let home = resolve_user_home_dir(user_home);
    let bin = resolve_b3_bin_str(b3_bin)?;
    let mut lines: Vec<String> = json_hosts_for_target(host)
        .iter()
        .map(|&jh| install_json_host(jh, scope, repo_root, &home, &bin, dry_run))
        .collect::<Result<_, _>>()?;
    if includes_git(host) {
        lines.push(if scope == HookScope::Project {
            install_git_hooks(repo_root, &bin, dry_run, force)?
        } else {
            "git (global): skipped (project-scope only)".to_string()
        });
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
    reject_global_git(host, scope)?;
    let home = resolve_user_home_dir(user_home);
    let mut lines: Vec<String> = json_hosts_for_target(host)
        .iter()
        .map(|&jh| uninstall_json_host(jh, scope, repo_root, &home, dry_run))
        .collect::<Result<_, _>>()?;
    if includes_git(host) {
        lines.push(if scope == HookScope::Project {
            uninstall_git_hooks(repo_root, dry_run)?
        } else {
            "git (global): skipped (project-scope only)".to_string()
        });
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
    reject_global_git(host, scope)?;
    let home = resolve_user_home_dir(user_home);
    let mut lines = Vec::new();
    let mut all_ok = true;
    for &jh in json_hosts_for_target(host) {
        let (msg, ok) = verify_json_host(jh, scope, repo_root, &home)?;
        all_ok &= ok;
        lines.push(msg);
    }
    if includes_git(host) {
        if scope == HookScope::Project {
            let (msg, ok) = verify_git_hooks(repo_root)?;
            all_ok &= ok;
            lines.push(msg);
        } else {
            lines.push("git (global): skipped (project-scope only)".to_string());
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
    let proj = match repo_root {
        Some(p) if !p.as_os_str().is_empty() => Some(resolve_project_root_dir(Some(p))?),
        _ => std::env::current_dir()
            .ok()
            .map(|p| PathBuf::from(normalize_abs_path_str(&p))),
    };
    let project_pref = proj.as_deref().map(default_project_preferences_path);
    let global_pref = default_global_preferences_path(Some(&home));
    let (cfg, warnings) = resolve_hook_config(project_pref.as_deref(), Some(&global_pref), None);

    let mut lines = vec![format!(
        "HOOK_CONFIG: enabled={} mode={}",
        cfg.enabled,
        cfg.mode.as_str()
    )];
    lines.extend(warnings);
    if let Some(ref p) = proj {
        for &jh in ALL_JSON_HOSTS {
            lines.push(verify_json_host(jh, HookScope::Project, Some(p), &home)?.0);
        }
        match verify_git_hooks(Some(p)) {
            Ok((msg, _)) => lines.push(msg),
            Err(e) => lines.push(format!("VERIFY_SKIP: git (project) ({})", e.message)),
        }
    }
    for &jh in ALL_JSON_HOSTS {
        lines.push(verify_json_host(jh, HookScope::Global, None, &home)?.0);
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

    fn git_ok(dir: &Path, args: &[&str]) {
        let no_env: [(&str, &str); 0] = [];
        assert_eq!(run_git(dir, args, &no_env, None).unwrap().exit_code, 0);
    }
    fn inst(
        h: HookHostTarget,
        s: HookScope,
        r: Option<&Path>,
        home: &Path,
        b: &str,
        f: bool,
    ) -> (String, i32) {
        install_hooks(h, s, r, Some(home), Some(b), false, f).unwrap()
    }
    fn uninst(h: HookHostTarget, s: HookScope, r: Option<&Path>, home: &Path) -> i32 {
        uninstall_hooks(h, s, r, Some(home), false).unwrap().1
    }
    fn ver(h: HookHostTarget, s: HookScope, r: Option<&Path>, home: &Path) -> i32 {
        verify_hooks(h, s, r, Some(home)).unwrap().1
    }

    #[test]
    fn json_hosts_preserve_keys_upgrade_codex_and_antigravity_shapes() {
        let (proj, home) = (temp_dir("json_proj"), temp_dir("json_home"));
        fs::create_dir_all(proj.join(".claude")).unwrap();
        let claude_path = proj.join(".claude/settings.json");
        let existing_claude = r#"{"model":"claude-sonnet","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo user"}]}]}}"#;
        fs::write(&claude_path, existing_claude).unwrap();

        let bin = if cfg!(windows) {
            r"C:\Program Files\B3\b3.exe"
        } else {
            "/opt/B3 Tools/José/b3"
        };
        for host in [
            HookHostTarget::Cursor,
            HookHostTarget::Claude,
            HookHostTarget::Codex,
            HookHostTarget::Antigravity,
        ] {
            assert_eq!(
                inst(host, HookScope::Project, Some(&proj), &home, bin, false).1,
                0
            );
            assert_eq!(ver(host, HookScope::Project, Some(&proj), &home), 0);
        }
        assert_eq!(
            fs::read_to_string(backup_path_for(&claude_path)).unwrap(),
            existing_claude
        );
        assert!(inst(
            HookHostTarget::Claude,
            HookScope::Project,
            Some(&proj),
            &home,
            bin,
            false
        )
        .0
        .contains("unchanged"));

        // Codex uses top-level "hooks" and uninstall cleans both nested and legacy root entries
        let codex_path = proj.join(".codex/hooks.json");
        let codex_json = parse_json(&fs::read_to_string(&codex_path).unwrap()).unwrap();
        assert!(
            codex_json.get("PreToolUse").is_none()
                && codex_json
                    .get("hooks")
                    .and_then(|h| h.get("Stop"))
                    .is_some()
        );
        fs::write(&codex_path, r#"{"model":"gpt-5","PreToolUse":[{"hooks":[{"type":"command","command":"b3 hook run --host codex --event PreToolUse"}]}],"hooks":{"Stop":[{"hooks":[{"type":"command","command":"b3 hook run --host codex --event Stop"}]}]}}"#).unwrap();
        assert_eq!(
            uninst(
                HookHostTarget::Codex,
                HookScope::Project,
                Some(&proj),
                &home
            ),
            0
        );
        let codex_after = parse_json(&fs::read_to_string(&codex_path).unwrap()).unwrap();
        assert_eq!(
            codex_after.get("model").and_then(JsonValue::as_str),
            Some("gpt-5")
        );
        assert!(codex_after.get("PreToolUse").is_none() && codex_after.get("hooks").is_none());

        // Antigravity: grouped PreToolUse/PostToolUse + TypedFlat Stop; upgrades legacy grouped Stop in-place
        let agy_path = proj.join(".agents/hooks.json");
        let agy_guard = parse_json(&fs::read_to_string(&agy_path).unwrap())
            .unwrap()
            .get("b3-native-guard")
            .unwrap()
            .clone();
        assert!(agy_guard.get("PreToolUse").unwrap().as_array().unwrap()[0]
            .get("hooks")
            .is_some());
        let stop0 = &agy_guard.get("Stop").unwrap().as_array().unwrap()[0];
        assert_eq!(
            stop0.get("type").and_then(JsonValue::as_str),
            Some("command")
        );
        assert!(stop0.get("hooks").is_none() && stop0.get("matcher").is_none());

        fs::write(&agy_path, r#"{"b3-native-guard":{"Stop":[{"hooks":[{"type":"command","command":"b3 hook run --host antigravity --event Stop"}]}]}}"#).unwrap();
        assert_eq!(
            ver(
                HookHostTarget::Antigravity,
                HookScope::Project,
                Some(&proj),
                &home
            ),
            1
        );
        assert_eq!(
            inst(
                HookHostTarget::Antigravity,
                HookScope::Project,
                Some(&proj),
                &home,
                "b3",
                false
            )
            .1,
            0
        );
        assert_eq!(
            ver(
                HookHostTarget::Antigravity,
                HookScope::Project,
                Some(&proj),
                &home
            ),
            0
        );

        // Global Antigravity -> ~/.gemini/config/hooks.json; uninstall Claude keeps user hook
        assert_eq!(
            inst(
                HookHostTarget::Antigravity,
                HookScope::Global,
                None,
                &home,
                "b3",
                false
            )
            .1,
            0
        );
        assert!(home.join(".gemini/config/hooks.json").is_file());
        assert_eq!(
            uninst(
                HookHostTarget::Claude,
                HookScope::Project,
                Some(&proj),
                &home
            ),
            0
        );
        let claude_after = parse_json(&fs::read_to_string(&claude_path).unwrap()).unwrap();
        assert_eq!(
            claude_after
                .get("hooks")
                .unwrap()
                .get("PreToolUse")
                .unwrap()
                .as_array()
                .unwrap()
                .len(),
            1
        );
        let _ = (fs::remove_dir_all(&proj), fs::remove_dir_all(&home));
    }

    #[test]
    fn git_hooks_shim_v2_preserves_perms_and_forwards_stdin_and_args() {
        let _lock = lock_hook_env();
        let (repo, home) = (temp_dir("git_hooks"), temp_dir("git_home"));
        git_ok(&repo, &["init"]);
        assert!(install_hooks(
            HookHostTarget::Git,
            HookScope::Global,
            Some(&repo),
            Some(&home),
            Some("b3"),
            false,
            false
        )
        .is_err());

        git_ok(&repo, &["config", "core.hooksPath", ".githooks"]);
        let hooks_dir = repo.join(".githooks");
        fs::create_dir_all(&hooks_dir).unwrap();
        let precommit_path = hooks_dir.join("pre-commit");
        fs::write(&precommit_path, "#!/bin/sh\necho user\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&precommit_path, fs::Permissions::from_mode(0o644)).unwrap();
        }
        fs::write(
            hooks_dir.join("pre-merge-commit"),
            "#!/bin/sh\n# b3-native-guard-hook v1 (pre-merge-commit)\n",
        )
        .unwrap();

        assert_eq!(
            inst(
                HookHostTarget::Git,
                HookScope::Project,
                Some(&repo),
                &home,
                "b3",
                false
            )
            .1,
            0
        );
        let backup_path = hooks_dir.join("pre-commit.b3-user");
        assert_eq!(
            fs::read_to_string(&backup_path).unwrap(),
            "#!/bin/sh\necho user\n"
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(&backup_path).unwrap().permissions().mode() & 0o777,
                0o644
            );
        }

        let shim = fs::read_to_string(&precommit_path).unwrap();
        assert!(
            !shim.contains('\r')
                && shim.contains("# b3-native-guard-hook v2 (pre-commit)")
                && !shim.contains("sh \"$USER_HOOK\"")
        );
        assert!(shim.contains("run_with_stdin \"$B3_BIN\" hook run --host git --event pre-commit --repo-root \"$REPO_ROOT\" -- \"$@\""));
        assert!(shim.contains("run_with_stdin env B3_HOOK_ACTIVE=1 \"$USER_HOOK\" \"$@\""));
        assert!(fs::read_to_string(hooks_dir.join("pre-merge-commit"))
            .unwrap()
            .contains("v2 (pre-merge-commit)"));

        // Conflict requires --force; uninstall restores .b3-user with original perms
        fs::write(&precommit_path, "#!/bin/sh\necho diff\n").unwrap();
        assert!(install_hooks(
            HookHostTarget::Git,
            HookScope::Project,
            Some(&repo),
            Some(&home),
            Some("b3"),
            false,
            false
        )
        .is_err());
        assert_eq!(
            inst(
                HookHostTarget::Git,
                HookScope::Project,
                Some(&repo),
                &home,
                "b3",
                true
            )
            .1,
            0
        );
        assert_eq!(
            uninst(HookHostTarget::Git, HookScope::Project, Some(&repo), &home),
            0
        );
        assert!(
            !backup_path.exists()
                && fs::read_to_string(&precommit_path).unwrap() == "#!/bin/sh\necho diff\n"
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(&precommit_path).unwrap().permissions().mode() & 0o777,
                0o644
            );
        }
        let _ = (fs::remove_dir_all(&repo), fs::remove_dir_all(&home));
    }

    #[test]
    fn worktree_common_dir_and_is_b3_managed_command() {
        assert!(is_b3_managed_command(
            r#""C:/Program Files/b3.exe" hook run --host cursor"#
        ));
        assert!(is_b3_managed_command("b3 hook run") && !is_b3_managed_command("echo user-hook"));

        let base = temp_dir("wt_José");
        let (main_repo, wt_repo, home) = (
            base.join("main repo"),
            base.join("wt repo"),
            base.join("home"),
        );
        fs::create_dir_all(&main_repo).unwrap();
        fs::create_dir_all(&home).unwrap();
        git_ok(&main_repo, &["init"]);
        git_ok(&main_repo, &["config", "user.email", "t@example.com"]);
        git_ok(&main_repo, &["config", "user.name", "Test"]);
        fs::write(main_repo.join("README.md"), "hi\n").unwrap();
        git_ok(&main_repo, &["add", "README.md"]);
        git_ok(&main_repo, &["commit", "-m", "init"]);
        git_ok(
            &main_repo,
            &["worktree", "add", "-b", "feat", &wt_repo.to_string_lossy()],
        );

        assert_eq!(
            inst(
                HookHostTarget::All,
                HookScope::Project,
                Some(&wt_repo),
                &home,
                "b3",
                false
            )
            .1,
            0
        );
        assert!(main_repo.join(".git/hooks/pre-push").is_file());
        assert_eq!(
            ver(
                HookHostTarget::All,
                HookScope::Project,
                Some(&wt_repo),
                &home
            ),
            0
        );
        assert_eq!(
            inst(
                HookHostTarget::All,
                HookScope::Global,
                None,
                &home,
                "b3",
                false
            )
            .1,
            0
        );
        assert_eq!(status_hooks(Some(&wt_repo), Some(&home)).unwrap().1, 0);
        let _ = fs::remove_dir_all(&base);
    }
}
