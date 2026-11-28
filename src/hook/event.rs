use crate::error::{fail, B3Error};
use crate::fs::has_control_chars;
use crate::json::{parse_json, JsonValue};

/// Maximum accepted raw hook JSON payload size (1 MiB).
pub(crate) const MAX_HOOK_PAYLOAD_BYTES: usize = 1024 * 1024;

/// Supported hook host identifiers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum HostId {
    Cursor,
    Claude,
    Codex,
    Antigravity,
    Git,
}

impl HostId {
    /// Parses a host identifier string (`cursor`, `claude`, `codex`, `antigravity`, `git`).
    pub(crate) fn parse(raw: &str) -> Result<Self, B3Error> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "cursor" => Ok(Self::Cursor),
            "claude" | "claude-code" | "claude_code" => Ok(Self::Claude),
            "codex" => Ok(Self::Codex),
            "antigravity" | "agy" => Ok(Self::Antigravity),
            "git" => Ok(Self::Git),
            _ => Err(fail(
                format!("HOOK_INVALID_HOST: unsupported host '{raw}'"),
                1,
            )),
        }
    }
}

/// Host-neutral normalized hook event category.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum EventKind {
    SessionStart,
    BeforeFileWrite,
    AfterFileWrite,
    BeforeCommand,
    AfterCommand,
    BeforeCommit,
    BeforePush,
    BeforeMerge,
    WorkerCompletion,
    TaskCompletion,
    SessionEnd,
    Unsupported,
}

impl EventKind {
    /// Returns a stable string representation of the normalized event kind.
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::SessionStart => "session_start",
            Self::BeforeFileWrite => "before_file_write",
            Self::AfterFileWrite => "after_file_write",
            Self::BeforeCommand => "before_command",
            Self::AfterCommand => "after_command",
            Self::BeforeCommit => "before_commit",
            Self::BeforePush => "before_push",
            Self::BeforeMerge => "before_merge",
            Self::WorkerCompletion => "worker_completion",
            Self::TaskCompletion => "task_completion",
            Self::SessionEnd => "session_end",
            Self::Unsupported => "unsupported",
        }
    }
}

/// Host-neutral normalized hook event metadata.
///
/// Intentionally omits raw prompts (`lastUserInput`, `prompt`), credentials, env secrets,
/// and conversation transcripts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct NormalizedEvent {
    pub(crate) event: EventKind,
    pub(crate) raw_event_name: String,
    pub(crate) project_root: Option<String>,
    pub(crate) cwd: Option<String>,
    pub(crate) affected_paths: Vec<String>,
    pub(crate) command: Option<String>,
    pub(crate) continuation_active: bool,
    pub(crate) git_args: Vec<String>,
    pub(crate) git_stdin: String,
}

fn has_non_ws_control_char(s: &str) -> bool {
    s.chars()
        .any(|c| c.is_control() && !matches!(c, '\t' | '\n' | '\r'))
}

fn validate_safe_text(val: &str, field: &str) -> Result<String, B3Error> {
    if has_control_chars(val) {
        return Err(fail(
            format!("HOOK_INVALID_FIELD: control characters rejected in {field}"),
            1,
        ));
    }
    Ok(val.to_string())
}

fn validate_non_ws_text(val: &str, field: &str) -> Result<String, B3Error> {
    if has_non_ws_control_char(val) {
        return Err(fail(
            format!("HOOK_INVALID_FIELD: control character rejected in {field}"),
            1,
        ));
    }
    Ok(val.to_string())
}

fn opt_safe_str(obj: &JsonValue, key: &str) -> Result<Option<String>, B3Error> {
    match obj.get(key).and_then(JsonValue::as_str) {
        Some(s) if !s.is_empty() => Ok(Some(validate_safe_text(s, key)?)),
        _ => Ok(None),
    }
}

fn first_opt_safe_str(obj: &JsonValue, keys: &[&str]) -> Result<Option<String>, B3Error> {
    for key in keys {
        if let Some(val) = opt_safe_str(obj, key)? {
            return Ok(Some(val));
        }
    }
    Ok(None)
}

fn first_array_safe_str(obj: &JsonValue, key: &str) -> Result<Option<String>, B3Error> {
    let Some(items) = obj.get(key).and_then(JsonValue::as_array) else {
        return Ok(None);
    };
    for item in items {
        if let Some(s) = item.as_str().filter(|s| !s.is_empty()) {
            return Ok(Some(validate_safe_text(s, key)?));
        }
    }
    Ok(None)
}

fn push_unique_path(paths: &mut Vec<String>, raw: &str, field: &str) -> Result<(), B3Error> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Ok(());
    }
    let clean = validate_safe_text(trimmed, field)?;
    if !paths.iter().any(|existing| existing == &clean) {
        paths.push(clean);
    }
    Ok(())
}

fn collect_object_paths(
    paths: &mut Vec<String>,
    obj: &JsonValue,
    keys: &[&str],
) -> Result<(), B3Error> {
    for key in keys {
        if let Some(s) = obj.get(key).and_then(JsonValue::as_str) {
            push_unique_path(paths, s, key)?;
        }
    }
    Ok(())
}

fn collect_paths_from_array(
    paths: &mut Vec<String>,
    val: Option<&JsonValue>,
    field: &str,
) -> Result<(), B3Error> {
    let Some(items) = val.and_then(JsonValue::as_array) else {
        return Ok(());
    };
    for item in items {
        if let Some(s) = item.as_str() {
            push_unique_path(paths, s, field)?;
        }
    }
    Ok(())
}

fn collect_paths_from_edits(
    paths: &mut Vec<String>,
    val: Option<&JsonValue>,
) -> Result<(), B3Error> {
    let Some(items) = val.and_then(JsonValue::as_array) else {
        return Ok(());
    };
    for item in items {
        collect_object_paths(paths, item, &["file_path", "path"])?;
    }
    Ok(())
}

fn extract_patch_paths(patch_text: &str, paths: &mut Vec<String>) -> Result<(), B3Error> {
    for line in patch_text.lines() {
        let trimmed = line.trim_end_matches('\r');
        for prefix in [
            "*** Update File: ",
            "*** Add File: ",
            "*** Delete File: ",
            "*** Move to: ",
        ] {
            if let Some(rest) = trimmed.strip_prefix(prefix) {
                push_unique_path(paths, rest, "patch_path")?;
            }
        }
        for (marker, strip_prefix) in [("+++ ", "b/"), ("--- ", "a/")] {
            if let Some(rest) = trimmed.strip_prefix(marker) {
                let candidate = rest.split('\t').next().unwrap_or(rest).trim();
                if candidate != "/dev/null" {
                    push_unique_path(
                        paths,
                        candidate.strip_prefix(strip_prefix).unwrap_or(candidate),
                        "patch_path",
                    )?;
                }
                break;
            }
        }
    }
    Ok(())
}

fn extract_command_field(obj: &JsonValue, key: &str) -> Result<Option<String>, B3Error> {
    let Some(val) = obj.get(key) else {
        return Ok(None);
    };
    if let Some(s) = val.as_str() {
        validate_non_ws_text(s, key)?;
        return Ok((!s.is_empty()).then(|| s.to_string()));
    }
    if let Some(arr) = val.as_array() {
        let mut parts = Vec::new();
        for item in arr {
            if let Some(s) = item.as_str() {
                validate_non_ws_text(s, key)?;
                if !s.is_empty() {
                    parts.push(s);
                }
            }
        }
        if !parts.is_empty() {
            return Ok(Some(parts.join(" ")));
        }
    }
    Ok(None)
}

fn extract_command_from(
    primary: Option<&JsonValue>,
    primary_keys: &[&str],
    fallback: &JsonValue,
) -> Result<Option<String>, B3Error> {
    if let Some(obj) = primary {
        for key in primary_keys {
            if let Some(cmd) = extract_command_field(obj, key)? {
                return Ok(Some(cmd));
            }
        }
    }
    extract_command_field(fallback, "command")
}

fn resolve_event_hint(event_hint: Option<&str>) -> Result<String, B3Error> {
    if let Some(hint) = event_hint {
        let trimmed = hint.trim();
        if !trimmed.is_empty() {
            return validate_safe_text(trimmed, "event_hint");
        }
    }
    Err(fail("HOOK_INVALID_EVENT: missing hook event name", 1))
}

fn resolve_raw_event_name(
    payload: &JsonValue,
    keys: &[&str],
    event_hint: Option<&str>,
) -> Result<String, B3Error> {
    if let Some(from_payload) = first_opt_safe_str(payload, keys)? {
        return Ok(from_payload);
    }
    resolve_event_hint(event_hint)
}

fn extract_project_root(
    payload: &JsonValue,
    array_keys: &[&str],
    str_keys: &[&str],
) -> Result<Option<String>, B3Error> {
    for key in array_keys {
        if let Some(val) = first_array_safe_str(payload, key)? {
            return Ok(Some(val));
        }
    }
    first_opt_safe_str(payload, str_keys)
}

fn parse_json_object(payload_raw: &str) -> Result<JsonValue, B3Error> {
    let val = parse_json(payload_raw)
        .map_err(|e| fail(format!("HOOK_INVALID_PAYLOAD: invalid JSON: {e}"), 1))?;
    if !val.is_object() {
        return Err(fail(
            "HOOK_INVALID_PAYLOAD: root JSON value must be an object",
            1,
        ));
    }
    Ok(val)
}

fn classify_cursor_event(raw_event: &str, tool_name: Option<&str>) -> EventKind {
    match raw_event {
        "preToolUse" => match tool_name {
            Some("Write" | "Edit" | "MultiEdit") => EventKind::BeforeFileWrite,
            Some("Shell") => EventKind::BeforeCommand,
            _ => EventKind::Unsupported,
        },
        "postToolUse" => match tool_name {
            Some("Write" | "Edit" | "MultiEdit") => EventKind::AfterFileWrite,
            Some("Shell") => EventKind::AfterCommand,
            _ => EventKind::Unsupported,
        },
        "beforeShellExecution" => EventKind::BeforeCommand,
        "afterShellExecution" => EventKind::AfterCommand,
        "afterFileEdit" => EventKind::AfterFileWrite,
        "subagentStop" => EventKind::WorkerCompletion,
        "stop" => EventKind::TaskCompletion,
        "sessionStart" => EventKind::SessionStart,
        "sessionEnd" => EventKind::SessionEnd,
        _ => EventKind::Unsupported,
    }
}

fn classify_claude_event(raw_event: &str, tool_name: Option<&str>) -> EventKind {
    match raw_event {
        "PreToolUse" => match tool_name {
            Some("Edit" | "Write" | "MultiEdit" | "NotebookEdit") => EventKind::BeforeFileWrite,
            Some("Bash") => EventKind::BeforeCommand,
            _ => EventKind::Unsupported,
        },
        "PostToolUse" => match tool_name {
            Some("Edit" | "Write" | "MultiEdit" | "NotebookEdit") => EventKind::AfterFileWrite,
            Some("Bash") => EventKind::AfterCommand,
            _ => EventKind::Unsupported,
        },
        "SubagentStop" => EventKind::WorkerCompletion,
        "Stop" => EventKind::TaskCompletion,
        "SessionStart" => EventKind::SessionStart,
        "SessionEnd" => EventKind::SessionEnd,
        _ => EventKind::Unsupported,
    }
}

fn classify_codex_event(raw_event: &str, tool_name: Option<&str>) -> EventKind {
    match raw_event {
        "PreToolUse" => match tool_name {
            Some("apply_patch" | "Write" | "Edit") => EventKind::BeforeFileWrite,
            Some("Bash" | "shell") => EventKind::BeforeCommand,
            _ => EventKind::Unsupported,
        },
        "PostToolUse" => match tool_name {
            Some("apply_patch" | "Write" | "Edit") => EventKind::AfterFileWrite,
            Some("Bash" | "shell") => EventKind::AfterCommand,
            _ => EventKind::Unsupported,
        },
        "Stop" => EventKind::TaskCompletion,
        "SessionStart" => EventKind::SessionStart,
        _ => EventKind::Unsupported,
    }
}

fn classify_antigravity_event(raw_event: &str, tool_name: Option<&str>) -> EventKind {
    let norm_tool = tool_name.map(|s| {
        let lower = s.trim().to_ascii_lowercase();
        lower
            .strip_prefix("cortex_step_type_")
            .unwrap_or(&lower)
            .to_string()
    });
    let is_write = matches!(
        norm_tool.as_deref(),
        Some(
            "write_to_file"
                | "write_file"
                | "edit_file"
                | "replace_file_content"
                | "multi_replace_file_content"
        )
    );
    let is_cmd = norm_tool.as_deref() == Some("run_command");

    match raw_event {
        "PreToolUse" | "PreInvocation" => {
            if is_write {
                EventKind::BeforeFileWrite
            } else if is_cmd {
                EventKind::BeforeCommand
            } else {
                EventKind::Unsupported
            }
        }
        "PostToolUse" | "PostInvocation" => {
            if is_write {
                EventKind::AfterFileWrite
            } else if is_cmd {
                EventKind::AfterCommand
            } else {
                EventKind::Unsupported
            }
        }
        "Stop" => EventKind::TaskCompletion,
        "SessionStart" => EventKind::SessionStart,
        _ => EventKind::Unsupported,
    }
}

fn classify_git_event(raw_event: &str) -> EventKind {
    match raw_event {
        "pre-commit" => EventKind::BeforeCommit,
        "pre-push" => EventKind::BeforePush,
        "pre-merge-commit" => EventKind::BeforeMerge,
        _ => EventKind::Unsupported,
    }
}

fn normalize_git_event(
    event_hint: Option<&str>,
    payload_raw: &str,
    safe_default_cwd: Option<String>,
) -> Result<NormalizedEvent, B3Error> {
    if payload_raw.trim().is_empty() {
        let raw_event_name = resolve_event_hint(event_hint)?;
        return Ok(NormalizedEvent {
            event: classify_git_event(&raw_event_name),
            raw_event_name,
            project_root: safe_default_cwd.clone(),
            cwd: safe_default_cwd,
            affected_paths: Vec::new(),
            command: None,
            continuation_active: false,
            git_args: Vec::new(),
            git_stdin: String::new(),
        });
    }

    if payload_raw.trim_start().starts_with('{') {
        let payload = parse_json_object(payload_raw)?;
        let raw_event_name =
            resolve_raw_event_name(&payload, &["hook_event_name", "event", "hook"], event_hint)?;
        let cwd = opt_safe_str(&payload, "cwd")?.or_else(|| safe_default_cwd.clone());
        let project_root =
            first_opt_safe_str(&payload, &["project_root", "repo_root"])?.or(safe_default_cwd);
        let git_stdin = match payload.get("git_stdin").and_then(JsonValue::as_str) {
            Some(s) => validate_non_ws_text(s, "git_stdin")?,
            None => String::new(),
        };
        return Ok(NormalizedEvent {
            event: classify_git_event(&raw_event_name),
            raw_event_name,
            project_root,
            cwd,
            affected_paths: Vec::new(),
            command: None,
            continuation_active: false,
            git_args: Vec::new(),
            git_stdin,
        });
    }

    validate_non_ws_text(payload_raw, "git_stdin")?;
    let raw_event_name = resolve_event_hint(event_hint)?;
    Ok(NormalizedEvent {
        event: classify_git_event(&raw_event_name),
        raw_event_name,
        project_root: safe_default_cwd.clone(),
        cwd: safe_default_cwd,
        affected_paths: Vec::new(),
        command: None,
        continuation_active: false,
        git_args: Vec::new(),
        git_stdin: payload_raw.to_string(),
    })
}

fn collect_standard_tool_paths(
    paths: &mut Vec<String>,
    host: HostId,
    payload: &JsonValue,
) -> Result<(), B3Error> {
    if let Some(ti) = payload.get("tool_input") {
        let keys: &[&str] = match host {
            HostId::Claude => &["file_path", "notebook_path", "path"],
            _ => &["file_path", "path"],
        };
        collect_object_paths(paths, ti, keys)?;
        if host == HostId::Cursor {
            collect_paths_from_array(paths, ti.get("paths"), "paths")?;
        }
        if matches!(host, HostId::Cursor | HostId::Claude) {
            collect_paths_from_edits(paths, ti.get("edits"))?;
        }
        if host == HostId::Codex {
            for k in ["patch", "input"] {
                if let Some(s) = ti.get(k).and_then(JsonValue::as_str) {
                    extract_patch_paths(s, paths)?;
                }
            }
            if let Some(s) = ti.as_str() {
                extract_patch_paths(s, paths)?;
            }
        }
    }
    if host == HostId::Cursor {
        collect_object_paths(paths, payload, &["file_path", "path"])?;
        collect_paths_from_array(paths, payload.get("paths"), "paths")?;
    } else if host == HostId::Codex {
        if let Some(s) = payload.get("input").and_then(JsonValue::as_str) {
            extract_patch_paths(s, paths)?;
        }
    }
    Ok(())
}

/// Normalizes a host-specific hook payload into a sanitized, host-neutral `NormalizedEvent`.
pub(crate) fn normalize_event(
    host: HostId,
    event_hint: Option<&str>,
    payload_raw: &str,
    default_cwd: Option<&str>,
) -> Result<NormalizedEvent, B3Error> {
    if payload_raw.len() > MAX_HOOK_PAYLOAD_BYTES {
        return Err(fail(
            format!("HOOK_PAYLOAD_TOO_LARGE: payload exceeds {MAX_HOOK_PAYLOAD_BYTES} bytes"),
            1,
        ));
    }

    let safe_default_cwd = match default_cwd {
        Some(s) if !s.trim().is_empty() => Some(validate_safe_text(s.trim(), "default_cwd")?),
        _ => None,
    };

    if host == HostId::Git {
        return normalize_git_event(event_hint, payload_raw, safe_default_cwd);
    }

    let payload = parse_json_object(payload_raw)?;
    let mut affected_paths = Vec::new();
    let cwd = opt_safe_str(&payload, "cwd")?.or(safe_default_cwd);

    let (raw_event_name, event, project_root, command, continuation_active) = match host {
        HostId::Cursor | HostId::Claude | HostId::Codex => {
            let raw_event_name =
                resolve_raw_event_name(&payload, &["hook_event_name", "event"], event_hint)?;
            let tool_name = opt_safe_str(&payload, "tool_name")?;
            let event = match host {
                HostId::Cursor => classify_cursor_event(&raw_event_name, tool_name.as_deref()),
                HostId::Claude => classify_claude_event(&raw_event_name, tool_name.as_deref()),
                HostId::Codex => classify_codex_event(&raw_event_name, tool_name.as_deref()),
                _ => unreachable!(),
            };
            collect_standard_tool_paths(&mut affected_paths, host, &payload)?;
            let command = if host == HostId::Claude {
                payload
                    .get("tool_input")
                    .and_then(|ti| extract_command_field(ti, "command").transpose())
                    .transpose()?
            } else {
                extract_command_from(payload.get("tool_input"), &["command"], &payload)?
            };
            let array_keys: &[&str] = if host == HostId::Cursor {
                &["workspace_roots"]
            } else {
                &[]
            };
            let project_root = extract_project_root(&payload, array_keys, &["project_root"])?;
            let continuation_active = payload
                .get("stop_hook_active")
                .and_then(JsonValue::as_bool)
                .unwrap_or(false)
                || (host == HostId::Cursor
                    && payload
                        .get("loop_count")
                        .and_then(JsonValue::as_i64)
                        .is_some_and(|n| n > 0));
            (
                raw_event_name,
                event,
                project_root,
                command,
                continuation_active,
            )
        }
        HostId::Antigravity => {
            let raw_event_name = resolve_raw_event_name(
                &payload,
                &["hookEventName", "hook_event_name"],
                event_hint,
            )?;
            let tool_call = payload.get("toolCall");
            let tool_name = match tool_call.and_then(|tc| tc.get("name")) {
                Some(v) => v
                    .as_str()
                    .filter(|s| !s.is_empty())
                    .map(|s| validate_safe_text(s, "toolCall.name"))
                    .transpose()?,
                None => first_opt_safe_str(&payload, &["toolName", "tool_name"])?,
            };
            let event = classify_antigravity_event(&raw_event_name, tool_name.as_deref());
            let args = tool_call.and_then(|tc| tc.get("args"));
            if let Some(args_obj) = args {
                collect_object_paths(
                    &mut affected_paths,
                    args_obj,
                    &["TargetFile", "Path", "file_path", "path", "target_file"],
                )?;
            }
            let command = extract_command_from(args, &["CommandLine", "command"], &payload)?;
            let project_root = extract_project_root(
                &payload,
                &["workspacePaths", "workspaceRoots"],
                &["projectRoot", "project_root"],
            )?;
            let continuation_active = payload
                .get("continuationActive")
                .and_then(JsonValue::as_bool)
                .unwrap_or(false);
            (
                raw_event_name,
                event,
                project_root,
                command,
                continuation_active,
            )
        }
        HostId::Git => unreachable!("handled above"),
    };

    Ok(NormalizedEvent {
        event,
        raw_event_name,
        project_root,
        cwd,
        affected_paths,
        command,
        continuation_active,
        git_args: Vec::new(),
        git_stdin: String::new(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_id_parse() {
        assert_eq!(HostId::parse("cursor").unwrap(), HostId::Cursor);
        assert_eq!(HostId::parse("Claude-Code").unwrap(), HostId::Claude);
        assert_eq!(HostId::parse("codex").unwrap(), HostId::Codex);
        assert_eq!(HostId::parse("agy").unwrap(), HostId::Antigravity);
        assert_eq!(HostId::parse("git").unwrap(), HostId::Git);
        assert!(HostId::parse("unknown").is_err());
    }

    #[test]
    fn normalize_cursor_events() {
        let write_payload = r#"{
            "hook_event_name": "preToolUse",
            "tool_name": "Edit",
            "tool_input": { "file_path": "src/main.rs", "paths": ["src/main.rs", "src/lib.rs"] },
            "workspace_roots": ["/repo"],
            "lastUserInput": "SECRET PROMPT DO NOT RETAIN"
        }"#;
        let ev = normalize_event(HostId::Cursor, None, write_payload, Some("/repo")).unwrap();
        assert_eq!(ev.event, EventKind::BeforeFileWrite);
        assert_eq!(ev.project_root.as_deref(), Some("/repo"));
        assert_eq!(ev.cwd.as_deref(), Some("/repo"));
        assert_eq!(ev.affected_paths, vec!["src/main.rs", "src/lib.rs"]);

        let shell_payload = r#"{"command": "git status", "cwd": "/repo"}"#;
        let ev_shell = normalize_event(
            HostId::Cursor,
            Some("beforeShellExecution"),
            shell_payload,
            None,
        )
        .unwrap();
        assert_eq!(ev_shell.event, EventKind::BeforeCommand);
        assert_eq!(ev_shell.command.as_deref(), Some("git status"));

        let ev_stop = normalize_event(
            HostId::Cursor,
            None,
            r#"{"hook_event_name": "stop", "loop_count": 2}"#,
            None,
        )
        .unwrap();
        assert_eq!(ev_stop.event, EventKind::TaskCompletion);
        assert!(ev_stop.continuation_active);

        let ev_sub = normalize_event(
            HostId::Cursor,
            None,
            r#"{"hook_event_name": "subagentStop", "loop_count": 0}"#,
            None,
        )
        .unwrap();
        assert_eq!(ev_sub.event, EventKind::WorkerCompletion);
        assert!(!ev_sub.continuation_active);
    }

    #[test]
    fn normalize_claude_and_codex_events() {
        let claude_payload = r#"{
            "hook_event_name": "PreToolUse",
            "tool_name": "MultiEdit",
            "tool_input": { "file_path": "src/a.rs", "edits": [{"file_path": "src/b.rs"}] },
            "cwd": "/proj"
        }"#;
        let ev = normalize_event(HostId::Claude, None, claude_payload, None).unwrap();
        assert_eq!(ev.event, EventKind::BeforeFileWrite);
        assert_eq!(ev.affected_paths, vec!["src/a.rs", "src/b.rs"]);

        let ev_stop = normalize_event(
            HostId::Claude,
            None,
            r#"{"hook_event_name": "Stop", "stop_hook_active": true}"#,
            None,
        )
        .unwrap();
        assert_eq!(ev_stop.event, EventKind::TaskCompletion);
        assert!(ev_stop.continuation_active);

        let codex_patch = r#"{
            "hook_event_name": "PreToolUse",
            "tool_name": "apply_patch",
            "tool_input": {
                "patch": "*** Begin Patch\n*** Update File: src/hook/mod.rs\n*** Add File: src/hook/new.rs\n*** Delete File: old.rs\n*** End Patch"
            }
        }"#;
        let ev_codex = normalize_event(HostId::Codex, None, codex_patch, None).unwrap();
        assert_eq!(ev_codex.event, EventKind::BeforeFileWrite);
        assert_eq!(
            ev_codex.affected_paths,
            vec!["src/hook/mod.rs", "src/hook/new.rs", "old.rs"]
        );

        let ev_shell = normalize_event(
            HostId::Codex,
            None,
            r#"{"hook_event_name": "PostToolUse", "tool_name": "shell", "tool_input": {"command": "cargo test"}}"#,
            None,
        )
        .unwrap();
        assert_eq!(ev_shell.event, EventKind::AfterCommand);
        assert_eq!(ev_shell.command.as_deref(), Some("cargo test"));
    }

    #[test]
    fn normalize_antigravity_events_and_cortex_prefixes() {
        let agy_write = r#"{
            "hookEventName": "PreToolUse",
            "toolCall": {
                "name": "CORTEX_STEP_TYPE_WRITE_TO_FILE",
                "args": { "TargetFile": "src/lib.rs", "target_file": "src/extra.rs" }
            },
            "workspacePaths": ["/ws"],
            "continuationActive": true
        }"#;
        let ev_write = normalize_event(HostId::Antigravity, None, agy_write, None).unwrap();
        assert_eq!(ev_write.event, EventKind::BeforeFileWrite);
        assert_eq!(ev_write.project_root.as_deref(), Some("/ws"));
        assert_eq!(ev_write.affected_paths, vec!["src/lib.rs", "src/extra.rs"]);
        assert!(ev_write.continuation_active);

        let agy_cmd = r#"{
            "hookEventName": "PostToolUse",
            "toolCall": {
                "name": "CORTEX_STEP_TYPE_RUN_COMMAND",
                "args": { "CommandLine": "git push" }
            }
        }"#;
        let ev_cmd = normalize_event(HostId::Antigravity, None, agy_cmd, None).unwrap();
        assert_eq!(ev_cmd.event, EventKind::AfterCommand);
        assert_eq!(ev_cmd.command.as_deref(), Some("git push"));

        let agy_lower = r#"{
            "hookEventName": "PreInvocation",
            "toolCall": { "name": "cortex_step_type_replace_file_content", "args": { "Path": "a.rs" } }
        }"#;
        let ev_lower = normalize_event(HostId::Antigravity, None, agy_lower, None).unwrap();
        assert_eq!(ev_lower.event, EventKind::BeforeFileWrite);
        assert_eq!(ev_lower.affected_paths, vec!["a.rs"]);
    }

    #[test]
    fn normalize_git_empty_json_and_raw_stdin() {
        let ev_empty =
            normalize_event(HostId::Git, Some("pre-commit"), "", Some("/git-repo")).unwrap();
        assert_eq!(ev_empty.event, EventKind::BeforeCommit);
        assert_eq!(ev_empty.project_root.as_deref(), Some("/git-repo"));
        assert_eq!(ev_empty.cwd.as_deref(), Some("/git-repo"));
        assert!(ev_empty.git_stdin.is_empty());
        assert!(ev_empty.git_args.is_empty());

        let json_payload = r#"{"hook":"pre-push","staged_files":["a.rs"],"project_root":"/repo","git_stdin":"refs/heads/main 1111 refs/heads/main 2222\n"}"#;
        let ev_json = normalize_event(HostId::Git, None, json_payload, None).unwrap();
        assert_eq!(ev_json.event, EventKind::BeforePush);
        assert!(ev_json.affected_paths.is_empty());
        assert_eq!(ev_json.project_root.as_deref(), Some("/repo"));
        assert_eq!(
            ev_json.git_stdin,
            "refs/heads/main 1111 refs/heads/main 2222\n"
        );

        let raw_stdin = "refs/heads/main 0000000000000000000000000000000000000000 refs/heads/main 1111111111111111111111111111111111111111\n";
        let ev_raw =
            normalize_event(HostId::Git, Some("pre-push"), raw_stdin, Some("/git-repo")).unwrap();
        assert_eq!(ev_raw.event, EventKind::BeforePush);
        assert_eq!(ev_raw.project_root.as_deref(), Some("/git-repo"));
        assert_eq!(ev_raw.cwd.as_deref(), Some("/git-repo"));
        assert_eq!(ev_raw.git_stdin, raw_stdin);

        assert!(normalize_event(HostId::Git, None, raw_stdin, None).is_err());
        assert!(normalize_event(HostId::Git, Some("pre-push"), "bad\x07line", None).is_err());
    }

    #[test]
    fn rejects_oversized_payload_and_control_chars() {
        let oversized = format!(
            "{{\"hook_event_name\":\"Stop\",\"pad\":\"{}\"}}",
            "a".repeat(MAX_HOOK_PAYLOAD_BYTES)
        );
        assert!(normalize_event(HostId::Claude, None, &oversized, None).is_err());

        let ctrl_path = r#"{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"bad\u0007path"}}"#;
        assert!(normalize_event(HostId::Claude, None, ctrl_path, None).is_err());
    }
}
