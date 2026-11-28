use crate::error::{fail, B3Error};
use crate::fs::has_control_chars;
use crate::json::{parse_json, JsonValue};

/// Maximum accepted raw hook JSON payload size (1 MiB).
pub const MAX_HOOK_PAYLOAD_BYTES: usize = 1024 * 1024;

/// Supported hook host identifiers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HostId {
    Cursor,
    Claude,
    Codex,
    Antigravity,
    Git,
}

impl HostId {
    /// Parses a host identifier string (`cursor`, `claude`, `codex`, `antigravity`, `git`).
    pub fn parse(raw: &str) -> Result<Self, B3Error> {
        let norm = raw.trim().to_ascii_lowercase();
        match norm.as_str() {
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

    /// Returns the canonical lowercase host identifier.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Cursor => "cursor",
            Self::Claude => "claude",
            Self::Codex => "codex",
            Self::Antigravity => "antigravity",
            Self::Git => "git",
        }
    }
}

/// Host-neutral normalized hook event category.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EventKind {
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
    pub fn as_str(self) -> &'static str {
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
pub struct NormalizedEvent {
    pub host: HostId,
    pub event: EventKind,
    pub raw_event_name: String,
    pub project_root: Option<String>,
    pub cwd: Option<String>,
    pub session_id: Option<String>,
    pub worker_id: Option<String>,
    pub run_id: Option<String>,
    pub operation_id: Option<String>,
    pub tool_name: Option<String>,
    pub affected_paths: Vec<String>,
    pub command: Option<String>,
    pub continuation_active: bool,
    pub state_fingerprint: Option<String>,
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
        if let Some(s) = item.as_str() {
            if !s.is_empty() {
                return Ok(Some(validate_safe_text(s, key)?));
            }
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
        for key in ["file_path", "path"] {
            if let Some(s) = item.get(key).and_then(JsonValue::as_str) {
                push_unique_path(paths, s, key)?;
            }
        }
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
        if let Some(rest) = trimmed.strip_prefix("+++ ") {
            let candidate = rest.split('\t').next().unwrap_or(rest).trim();
            if candidate != "/dev/null" {
                let stripped = candidate.strip_prefix("b/").unwrap_or(candidate);
                push_unique_path(paths, stripped, "patch_path")?;
            }
        } else if let Some(rest) = trimmed.strip_prefix("--- ") {
            let candidate = rest.split('\t').next().unwrap_or(rest).trim();
            if candidate != "/dev/null" {
                let stripped = candidate.strip_prefix("a/").unwrap_or(candidate);
                push_unique_path(paths, stripped, "patch_path")?;
            }
        }
    }
    Ok(())
}

fn has_non_ws_control_char(s: &str) -> bool {
    s.chars()
        .any(|c| c.is_control() && !matches!(c, '\t' | '\n' | '\r'))
}

fn extract_command_field(obj: &JsonValue, key: &str) -> Result<Option<String>, B3Error> {
    let Some(val) = obj.get(key) else {
        return Ok(None);
    };
    if let Some(s) = val.as_str() {
        if has_non_ws_control_char(s) {
            return Err(fail(
                format!("HOOK_INVALID_FIELD: control character rejected in {key}"),
                1,
            ));
        }
        return if s.is_empty() {
            Ok(None)
        } else {
            Ok(Some(s.to_string()))
        };
    }
    if let Some(arr) = val.as_array() {
        let mut parts = Vec::new();
        for item in arr {
            if let Some(s) = item.as_str() {
                if has_non_ws_control_char(s) {
                    return Err(fail(
                        format!("HOOK_INVALID_FIELD: control character rejected in {key}"),
                        1,
                    ));
                }
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

fn resolve_raw_event_name(
    payload: &JsonValue,
    keys: &[&str],
    event_hint: Option<&str>,
) -> Result<String, B3Error> {
    if let Some(from_payload) = first_opt_safe_str(payload, keys)? {
        return Ok(from_payload);
    }
    if let Some(hint) = event_hint {
        let trimmed = hint.trim();
        if !trimmed.is_empty() {
            return validate_safe_text(trimmed, "event_hint");
        }
    }
    Err(fail("HOOK_INVALID_EVENT: missing hook event name", 1))
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
    let is_write_tool = matches!(
        tool_name,
        Some(
            "write_to_file"
                | "write_file"
                | "edit_file"
                | "replace_file_content"
                | "multi_replace_file_content"
        )
    );
    match raw_event {
        "PreToolUse" | "PreInvocation" => {
            if is_write_tool {
                EventKind::BeforeFileWrite
            } else if tool_name == Some("run_command") {
                EventKind::BeforeCommand
            } else {
                EventKind::Unsupported
            }
        }
        "PostToolUse" | "PostInvocation" => {
            if is_write_tool {
                EventKind::AfterFileWrite
            } else if tool_name == Some("run_command") {
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

/// Normalizes a host-specific hook payload into a sanitized, host-neutral `NormalizedEvent`.
pub fn normalize_event(
    host: HostId,
    event_hint: Option<&str>,
    payload_raw: &str,
    default_cwd: Option<&str>,
) -> Result<NormalizedEvent, B3Error> {
    if payload_raw.len() > MAX_HOOK_PAYLOAD_BYTES {
        return Err(fail(
            format!(
                "HOOK_PAYLOAD_TOO_LARGE: payload exceeds {} bytes",
                MAX_HOOK_PAYLOAD_BYTES
            ),
            1,
        ));
    }

    let safe_default_cwd = match default_cwd {
        Some(s) if !s.trim().is_empty() => Some(validate_safe_text(s.trim(), "default_cwd")?),
        _ => None,
    };

    let payload = if host == HostId::Git && payload_raw.trim().is_empty() {
        JsonValue::Object(Vec::new())
    } else {
        let val = parse_json(payload_raw)
            .map_err(|e| fail(format!("HOOK_INVALID_PAYLOAD: invalid JSON: {e}"), 1))?;
        if !val.is_object() {
            return Err(fail(
                "HOOK_INVALID_PAYLOAD: root JSON value must be an object",
                1,
            ));
        }
        val
    };

    let mut affected_paths = Vec::new();

    match host {
        HostId::Cursor => {
            let raw_event_name =
                resolve_raw_event_name(&payload, &["hook_event_name", "event"], event_hint)?;
            let tool_name = opt_safe_str(&payload, "tool_name")?;
            let event = classify_cursor_event(&raw_event_name, tool_name.as_deref());

            if let Some(ti) = payload.get("tool_input") {
                for key in ["file_path", "path"] {
                    if let Some(s) = ti.get(key).and_then(JsonValue::as_str) {
                        push_unique_path(&mut affected_paths, s, key)?;
                    }
                }
                collect_paths_from_array(&mut affected_paths, ti.get("paths"), "paths")?;
                collect_paths_from_edits(&mut affected_paths, ti.get("edits"))?;
            }
            for key in ["file_path", "path"] {
                if let Some(s) = payload.get(key).and_then(JsonValue::as_str) {
                    push_unique_path(&mut affected_paths, s, key)?;
                }
            }
            collect_paths_from_array(&mut affected_paths, payload.get("paths"), "paths")?;

            let command = payload
                .get("tool_input")
                .and_then(|ti| extract_command_field(ti, "command").transpose())
                .transpose()?
                .or(extract_command_field(&payload, "command")?);

            let project_root = first_array_safe_str(&payload, "workspace_roots")?
                .or(opt_safe_str(&payload, "project_root")?);
            let cwd = opt_safe_str(&payload, "cwd")?.or(safe_default_cwd);
            let session_id = first_opt_safe_str(&payload, &["conversation_id", "session_id"])?;
            let worker_id =
                first_opt_safe_str(&payload, &["worker_id", "subagent_id", "agent_id"])?;
            let run_id = first_opt_safe_str(&payload, &["run_id", "b3_run_id"])?;
            let operation_id =
                first_opt_safe_str(&payload, &["tool_use_id", "call_id", "operation_id"])?;
            let continuation_active = payload
                .get("stop_hook_active")
                .and_then(JsonValue::as_bool)
                .unwrap_or(false)
                || payload
                    .get("loop_count")
                    .and_then(JsonValue::as_i64)
                    .is_some_and(|n| n > 0);
            let state_fingerprint = opt_safe_str(&payload, "state_fingerprint")?;

            Ok(NormalizedEvent {
                host,
                event,
                raw_event_name,
                project_root,
                cwd,
                session_id,
                worker_id,
                run_id,
                operation_id,
                tool_name,
                affected_paths,
                command,
                continuation_active,
                state_fingerprint,
            })
        }
        HostId::Claude => {
            let raw_event_name =
                resolve_raw_event_name(&payload, &["hook_event_name", "event"], event_hint)?;
            let tool_name = opt_safe_str(&payload, "tool_name")?;
            let event = classify_claude_event(&raw_event_name, tool_name.as_deref());

            if let Some(ti) = payload.get("tool_input") {
                for key in ["file_path", "notebook_path", "path"] {
                    if let Some(s) = ti.get(key).and_then(JsonValue::as_str) {
                        push_unique_path(&mut affected_paths, s, key)?;
                    }
                }
                collect_paths_from_edits(&mut affected_paths, ti.get("edits"))?;
            }

            let command = payload
                .get("tool_input")
                .and_then(|ti| extract_command_field(ti, "command").transpose())
                .transpose()?;

            let project_root = opt_safe_str(&payload, "project_root")?;
            let cwd = opt_safe_str(&payload, "cwd")?.or(safe_default_cwd);
            let session_id = opt_safe_str(&payload, "session_id")?;
            let worker_id =
                first_opt_safe_str(&payload, &["worker_id", "agent_id", "subagent_id"])?;
            let run_id = first_opt_safe_str(&payload, &["run_id", "b3_run_id"])?;
            let operation_id = first_opt_safe_str(&payload, &["tool_use_id", "operation_id"])?;
            let continuation_active = payload
                .get("stop_hook_active")
                .and_then(JsonValue::as_bool)
                .unwrap_or(false);
            let state_fingerprint = opt_safe_str(&payload, "state_fingerprint")?;

            Ok(NormalizedEvent {
                host,
                event,
                raw_event_name,
                project_root,
                cwd,
                session_id,
                worker_id,
                run_id,
                operation_id,
                tool_name,
                affected_paths,
                command,
                continuation_active,
                state_fingerprint,
            })
        }
        HostId::Codex => {
            let raw_event_name =
                resolve_raw_event_name(&payload, &["hook_event_name", "event"], event_hint)?;
            let tool_name = opt_safe_str(&payload, "tool_name")?;
            let event = classify_codex_event(&raw_event_name, tool_name.as_deref());

            if let Some(ti) = payload.get("tool_input") {
                for key in ["file_path", "path"] {
                    if let Some(s) = ti.get(key).and_then(JsonValue::as_str) {
                        push_unique_path(&mut affected_paths, s, key)?;
                    }
                }
                for patch_key in ["patch", "input"] {
                    if let Some(patch_str) = ti.get(patch_key).and_then(JsonValue::as_str) {
                        extract_patch_paths(patch_str, &mut affected_paths)?;
                    }
                }
                if let Some(ti_str) = ti.as_str() {
                    extract_patch_paths(ti_str, &mut affected_paths)?;
                }
            }
            if let Some(input_str) = payload.get("input").and_then(JsonValue::as_str) {
                extract_patch_paths(input_str, &mut affected_paths)?;
            }

            let command = payload
                .get("tool_input")
                .and_then(|ti| extract_command_field(ti, "command").transpose())
                .transpose()?
                .or(extract_command_field(&payload, "command")?);

            let project_root = opt_safe_str(&payload, "project_root")?;
            let cwd = opt_safe_str(&payload, "cwd")?.or(safe_default_cwd);
            let session_id = opt_safe_str(&payload, "session_id")?;
            let worker_id = first_opt_safe_str(&payload, &["worker_id", "agent_id"])?;
            let run_id = first_opt_safe_str(&payload, &["run_id", "b3_run_id"])?;
            let operation_id =
                first_opt_safe_str(&payload, &["tool_use_id", "call_id", "operation_id"])?;
            let continuation_active = payload
                .get("stop_hook_active")
                .and_then(JsonValue::as_bool)
                .unwrap_or(false);
            let state_fingerprint = opt_safe_str(&payload, "state_fingerprint")?;

            Ok(NormalizedEvent {
                host,
                event,
                raw_event_name,
                project_root,
                cwd,
                session_id,
                worker_id,
                run_id,
                operation_id,
                tool_name,
                affected_paths,
                command,
                continuation_active,
                state_fingerprint,
            })
        }
        HostId::Antigravity => {
            let raw_event_name = resolve_raw_event_name(
                &payload,
                &["hookEventName", "hook_event_name"],
                event_hint,
            )?;
            let tool_call = payload.get("toolCall");
            let tool_name = match tool_call.and_then(|tc| tc.get("name")) {
                Some(v) => match v.as_str() {
                    Some(s) if !s.is_empty() => Some(validate_safe_text(s, "toolCall.name")?),
                    _ => None,
                },
                None => first_opt_safe_str(&payload, &["toolName", "tool_name"])?,
            };
            let event = classify_antigravity_event(&raw_event_name, tool_name.as_deref());

            if let Some(args) = tool_call.and_then(|tc| tc.get("args")) {
                for key in ["Path", "TargetFile", "file_path", "path"] {
                    if let Some(s) = args.get(key).and_then(JsonValue::as_str) {
                        push_unique_path(&mut affected_paths, s, key)?;
                    }
                }
            }

            let command = tool_call
                .and_then(|tc| tc.get("args"))
                .and_then(|args| extract_command_field(args, "CommandLine").transpose())
                .transpose()?
                .or(extract_command_field(&payload, "command")?);

            let project_root = first_array_safe_str(&payload, "workspacePaths")?
                .or(first_array_safe_str(&payload, "workspaceRoots")?)
                .or(first_opt_safe_str(
                    &payload,
                    &["projectRoot", "project_root"],
                )?);
            let cwd = opt_safe_str(&payload, "cwd")?.or(safe_default_cwd);
            let session_id =
                first_opt_safe_str(&payload, &["conversationId", "sessionId", "session_id"])?;
            let worker_id = first_opt_safe_str(&payload, &["workerId", "worker_id", "agentId"])?;
            let run_id = first_opt_safe_str(&payload, &["runId", "run_id"])?;
            let operation_id = match tool_call.and_then(|tc| tc.get("id")) {
                Some(v) => match v.as_str() {
                    Some(s) if !s.is_empty() => Some(validate_safe_text(s, "toolCall.id")?),
                    _ => None,
                },
                None => first_opt_safe_str(&payload, &["invocationId", "operationId"])?,
            };
            let continuation_active = payload
                .get("continuationActive")
                .and_then(JsonValue::as_bool)
                .unwrap_or(false);
            let state_fingerprint =
                first_opt_safe_str(&payload, &["stateFingerprint", "state_fingerprint"])?;

            Ok(NormalizedEvent {
                host,
                event,
                raw_event_name,
                project_root,
                cwd,
                session_id,
                worker_id,
                run_id,
                operation_id,
                tool_name,
                affected_paths,
                command,
                continuation_active,
                state_fingerprint,
            })
        }
        HostId::Git => {
            let raw_event_name = resolve_raw_event_name(
                &payload,
                &["hook_event_name", "event", "hook"],
                event_hint,
            )?;
            let event = classify_git_event(&raw_event_name);

            collect_paths_from_array(&mut affected_paths, payload.get("paths"), "paths")?;
            collect_paths_from_array(
                &mut affected_paths,
                payload.get("staged_files"),
                "staged_files",
            )?;

            let cwd = opt_safe_str(&payload, "cwd")?.or_else(|| safe_default_cwd.clone());
            let project_root =
                first_opt_safe_str(&payload, &["project_root", "repo_root"])?.or(safe_default_cwd);
            let session_id = opt_safe_str(&payload, "session_id")?;
            let worker_id = opt_safe_str(&payload, "worker_id")?;
            let run_id = first_opt_safe_str(&payload, &["run_id", "b3_run_id"])?;
            let operation_id = opt_safe_str(&payload, "operation_id")?;
            let state_fingerprint = opt_safe_str(&payload, "state_fingerprint")?;

            Ok(NormalizedEvent {
                host,
                event,
                raw_event_name,
                project_root,
                cwd,
                session_id,
                worker_id,
                run_id,
                operation_id,
                tool_name: None,
                affected_paths,
                command: None,
                continuation_active: false,
                state_fingerprint,
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_id_parse_and_as_str() {
        assert_eq!(HostId::parse("cursor").unwrap(), HostId::Cursor);
        assert_eq!(HostId::parse("Claude-Code").unwrap(), HostId::Claude);
        assert_eq!(HostId::parse("codex").unwrap(), HostId::Codex);
        assert_eq!(HostId::parse("agy").unwrap(), HostId::Antigravity);
        assert_eq!(HostId::parse("git").unwrap(), HostId::Git);
        assert_eq!(HostId::Antigravity.as_str(), "antigravity");
        assert!(HostId::parse("unknown").is_err());
    }

    #[test]
    fn normalize_cursor_events() {
        let write_payload = r#"{
            "hook_event_name": "preToolUse",
            "tool_name": "Edit",
            "tool_input": { "file_path": "src/main.rs", "paths": ["src/main.rs", "src/lib.rs"] },
            "workspace_roots": ["/repo"],
            "conversation_id": "conv-123",
            "lastUserInput": "SECRET PROMPT DO NOT RETAIN"
        }"#;
        let ev = normalize_event(HostId::Cursor, None, write_payload, Some("/repo")).unwrap();
        assert_eq!(ev.event, EventKind::BeforeFileWrite);
        assert_eq!(ev.project_root.as_deref(), Some("/repo"));
        assert_eq!(ev.cwd.as_deref(), Some("/repo"));
        assert_eq!(ev.session_id.as_deref(), Some("conv-123"));
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

        let stop_payload = r#"{"hook_event_name": "stop", "loop_count": 2}"#;
        let ev_stop = normalize_event(HostId::Cursor, None, stop_payload, None).unwrap();
        assert_eq!(ev_stop.event, EventKind::TaskCompletion);
        assert!(ev_stop.continuation_active);

        let sub_payload = r#"{"hook_event_name": "subagentStop", "loop_count": 0}"#;
        let ev_sub = normalize_event(HostId::Cursor, None, sub_payload, None).unwrap();
        assert_eq!(ev_sub.event, EventKind::WorkerCompletion);
        assert!(!ev_sub.continuation_active);
    }

    #[test]
    fn normalize_claude_events() {
        let payload = r#"{
            "hook_event_name": "PreToolUse",
            "tool_name": "MultiEdit",
            "tool_input": {
                "file_path": "src/a.rs",
                "edits": [{"file_path": "src/b.rs"}]
            },
            "cwd": "/proj",
            "session_id": "sess-1",
            "tool_use_id": "toolu_1"
        }"#;
        let ev = normalize_event(HostId::Claude, None, payload, None).unwrap();
        assert_eq!(ev.event, EventKind::BeforeFileWrite);
        assert_eq!(ev.affected_paths, vec!["src/a.rs", "src/b.rs"]);
        assert_eq!(ev.operation_id.as_deref(), Some("toolu_1"));

        let stop = r#"{"hook_event_name": "Stop", "stop_hook_active": true}"#;
        let ev_stop = normalize_event(HostId::Claude, None, stop, None).unwrap();
        assert_eq!(ev_stop.event, EventKind::TaskCompletion);
        assert!(ev_stop.continuation_active);
    }

    #[test]
    fn normalize_codex_apply_patch_and_shell() {
        let patch_payload = r#"{
            "hook_event_name": "PreToolUse",
            "tool_name": "apply_patch",
            "tool_input": {
                "patch": "*** Begin Patch\n*** Update File: src/hook/config.rs\n*** Add File: src/hook/new.rs\n*** Delete File: old.rs\n*** End Patch"
            },
            "cwd": "/repo",
            "session_id": "codex-1",
            "tool_use_id": "call-9"
        }"#;
        let ev = normalize_event(HostId::Codex, None, patch_payload, None).unwrap();
        assert_eq!(ev.event, EventKind::BeforeFileWrite);
        assert_eq!(
            ev.affected_paths,
            vec!["src/hook/config.rs", "src/hook/new.rs", "old.rs"]
        );
        assert_eq!(ev.operation_id.as_deref(), Some("call-9"));

        let shell_payload = r#"{
            "hook_event_name": "PostToolUse",
            "tool_name": "shell",
            "tool_input": {"command": "cargo test"}
        }"#;
        let ev_shell = normalize_event(HostId::Codex, None, shell_payload, None).unwrap();
        assert_eq!(ev_shell.event, EventKind::AfterCommand);
        assert_eq!(ev_shell.command.as_deref(), Some("cargo test"));
    }

    #[test]
    fn normalize_antigravity_and_git_events() {
        let agy_payload = r#"{
            "hookEventName": "PreToolUse",
            "toolCall": {
                "id": "tc-42",
                "name": "replace_file_content",
                "args": { "TargetFile": "src/lib.rs" }
            },
            "workspacePaths": ["/ws"],
            "conversationId": "conv-agy",
            "continuationActive": true
        }"#;
        let ev_agy = normalize_event(HostId::Antigravity, None, agy_payload, None).unwrap();
        assert_eq!(ev_agy.event, EventKind::BeforeFileWrite);
        assert_eq!(ev_agy.project_root.as_deref(), Some("/ws"));
        assert_eq!(ev_agy.session_id.as_deref(), Some("conv-agy"));
        assert_eq!(ev_agy.operation_id.as_deref(), Some("tc-42"));
        assert_eq!(ev_agy.affected_paths, vec!["src/lib.rs"]);
        assert!(ev_agy.continuation_active);

        let ev_git =
            normalize_event(HostId::Git, Some("pre-commit"), "", Some("/git-repo")).unwrap();
        assert_eq!(ev_git.event, EventKind::BeforeCommit);
        assert_eq!(ev_git.project_root.as_deref(), Some("/git-repo"));
        assert_eq!(ev_git.cwd.as_deref(), Some("/git-repo"));

        let ev_msg = normalize_event(HostId::Git, Some("commit-msg"), "{}", None).unwrap();
        assert_eq!(ev_msg.event, EventKind::Unsupported);
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
