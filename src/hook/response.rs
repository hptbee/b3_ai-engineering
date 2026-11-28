use crate::hook::event::{EventKind, HostId};
use crate::json::JsonValue;

/// Host-neutral evaluation outcome for a hook invocation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HookOutcome {
    Allow,
    Advisory { message: String },
    Deny { message: String },
}

/// Host-specific formatted output streams and exit status.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostResponse {
    pub stdout: String,
    pub stderr: String,
    pub exit_code: i32,
}

impl HostResponse {
    fn new(stdout: impl Into<String>, stderr: impl Into<String>, exit_code: i32) -> Self {
        Self {
            stdout: stdout.into(),
            stderr: stderr.into(),
            exit_code,
        }
    }
}

fn json_field(k: &str, v: &str) -> (String, JsonValue) {
    (k.to_string(), JsonValue::str(v))
}

/// Formats a `HookOutcome` into the exact protocol expected by `host`.
pub fn format_response(
    host: HostId,
    raw_event: &str,
    kind: EventKind,
    outcome: &HookOutcome,
) -> HostResponse {
    match host {
        HostId::Cursor => format_cursor(raw_event, kind, outcome),
        HostId::Claude | HostId::Codex => format_plain_exit(outcome, 2),
        HostId::Antigravity => format_antigravity(raw_event, kind, outcome),
        HostId::Git => format_plain_exit(outcome, 1),
    }
}

fn format_cursor(raw_event: &str, kind: EventKind, outcome: &HookOutcome) -> HostResponse {
    let is_blocking_pre = matches!(kind, EventKind::BeforeFileWrite | EventKind::BeforeCommand)
        || matches!(
            raw_event,
            "preToolUse" | "beforeShellExecution" | "beforeMCPExecution" | "subagentStart"
        );
    if !is_blocking_pre {
        return match outcome {
            HookOutcome::Allow => HostResponse::new("{}", "", 0),
            HookOutcome::Advisory { message } => HostResponse::new("{}", message, 0),
            HookOutcome::Deny { message } => HostResponse::new("{}", message, 2),
        };
    }
    match outcome {
        HookOutcome::Allow => HostResponse::new(
            JsonValue::obj(vec![json_field("permission", "allow")]).to_json_string(),
            "",
            0,
        ),
        HookOutcome::Advisory { message } => HostResponse::new(
            JsonValue::obj(vec![json_field("permission", "allow")]).to_json_string(),
            message,
            0,
        ),
        HookOutcome::Deny { message } => HostResponse::new(
            JsonValue::obj(vec![
                json_field("permission", "deny"),
                json_field("user_message", message),
                json_field("agent_message", message),
            ])
            .to_json_string(),
            message,
            2,
        ),
    }
}

fn format_plain_exit(outcome: &HookOutcome, deny_exit_code: i32) -> HostResponse {
    match outcome {
        HookOutcome::Allow => HostResponse::new("", "", 0),
        HookOutcome::Advisory { message } => HostResponse::new("", message, 0),
        HookOutcome::Deny { message } => HostResponse::new("", message, deny_exit_code),
    }
}

fn format_antigravity(raw_event: &str, kind: EventKind, outcome: &HookOutcome) -> HostResponse {
    let is_stop = matches!(
        kind,
        EventKind::TaskCompletion | EventKind::WorkerCompletion
    ) || raw_event == "Stop";
    let is_pre_tool = matches!(kind, EventKind::BeforeFileWrite | EventKind::BeforeCommand)
        || matches!(raw_event, "PreToolUse" | "PreInvocation");

    if is_stop || is_pre_tool {
        let allow_json = JsonValue::obj(vec![json_field("decision", "allow")]).to_json_string();
        return match outcome {
            HookOutcome::Allow => HostResponse::new(allow_json, "", 0),
            HookOutcome::Advisory { message } => HostResponse::new(allow_json, message, 0),
            HookOutcome::Deny { message } => {
                let decision = if is_stop { "continue" } else { "deny" };
                let body = JsonValue::obj(vec![
                    json_field("decision", decision),
                    json_field("reason", message),
                ])
                .to_json_string();
                let stderr = if is_stop { message.as_str() } else { "" };
                HostResponse::new(body, stderr, 0)
            }
        };
    }

    let stderr = match outcome {
        HookOutcome::Allow => "",
        HookOutcome::Advisory { message } | HookOutcome::Deny { message } => message.as_str(),
    };
    HostResponse::new("{}", stderr, 0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::json::parse_json;

    #[test]
    fn cursor_blocking_and_non_blocking_responses() {
        let allow = format_response(
            HostId::Cursor,
            "preToolUse",
            EventKind::BeforeFileWrite,
            &HookOutcome::Allow,
        );
        assert_eq!(allow.exit_code, 0);
        assert_eq!(
            parse_json(&allow.stdout)
                .unwrap()
                .get("permission")
                .and_then(JsonValue::as_str),
            Some("allow")
        );

        let deny = format_response(
            HostId::Cursor,
            "beforeShellExecution",
            EventKind::BeforeCommand,
            &HookOutcome::Deny {
                message: "blocked".into(),
            },
        );
        assert_eq!((deny.exit_code, deny.stderr.as_str()), (2, "blocked"));
        let jd = parse_json(&deny.stdout).unwrap();
        assert_eq!(
            jd.get("permission").and_then(JsonValue::as_str),
            Some("deny")
        );
        assert_eq!(
            jd.get("user_message").and_then(JsonValue::as_str),
            Some("blocked")
        );

        assert_eq!(
            format_response(
                HostId::Cursor,
                "postToolUse",
                EventKind::AfterFileWrite,
                &HookOutcome::Advisory {
                    message: "note".into()
                },
            ),
            HostResponse::new("{}", "note", 0)
        );
        assert_eq!(
            format_response(
                HostId::Cursor,
                "stop",
                EventKind::TaskCompletion,
                &HookOutcome::Deny {
                    message: "verify".into()
                },
            ),
            HostResponse::new("{}", "verify", 2)
        );
    }

    #[test]
    fn claude_codex_and_git_responses() {
        for (host, deny_code) in [(HostId::Claude, 2), (HostId::Codex, 2), (HostId::Git, 1)] {
            assert_eq!(
                format_response(
                    host,
                    "PreToolUse",
                    EventKind::BeforeFileWrite,
                    &HookOutcome::Allow
                ),
                HostResponse::new("", "", 0)
            );
            assert_eq!(
                format_response(
                    host,
                    "PreToolUse",
                    EventKind::BeforeFileWrite,
                    &HookOutcome::Advisory {
                        message: "warn".into()
                    },
                ),
                HostResponse::new("", "warn", 0)
            );
            assert_eq!(
                format_response(
                    host,
                    "PreToolUse",
                    EventKind::BeforeCommand,
                    &HookOutcome::Deny {
                        message: "denied".into()
                    },
                ),
                HostResponse::new("", "denied", deny_code)
            );
        }
    }

    #[test]
    fn antigravity_responses_match_protocol() {
        let pre_allow = format_response(
            HostId::Antigravity,
            "PreToolUse",
            EventKind::BeforeFileWrite,
            &HookOutcome::Allow,
        );
        assert_eq!(
            parse_json(&pre_allow.stdout)
                .unwrap()
                .get("decision")
                .and_then(JsonValue::as_str),
            Some("allow")
        );

        let pre_deny = format_response(
            HostId::Antigravity,
            "PreInvocation",
            EventKind::BeforeCommand,
            &HookOutcome::Deny {
                message: "not allowed".into(),
            },
        );
        assert_eq!((pre_deny.exit_code, pre_deny.stderr.as_str()), (0, ""));
        let j = parse_json(&pre_deny.stdout).unwrap();
        assert_eq!(j.get("decision").and_then(JsonValue::as_str), Some("deny"));
        assert_eq!(
            j.get("reason").and_then(JsonValue::as_str),
            Some("not allowed")
        );

        assert_eq!(
            format_response(
                HostId::Antigravity,
                "PostToolUse",
                EventKind::AfterFileWrite,
                &HookOutcome::Advisory {
                    message: "heads up".into()
                },
            ),
            HostResponse::new("{}", "heads up", 0)
        );

        let stop_allow = format_response(
            HostId::Antigravity,
            "Stop",
            EventKind::TaskCompletion,
            &HookOutcome::Allow,
        );
        assert_eq!(
            parse_json(&stop_allow.stdout)
                .unwrap()
                .get("decision")
                .and_then(JsonValue::as_str),
            Some("allow")
        );

        let stop_deny = format_response(
            HostId::Antigravity,
            "Stop",
            EventKind::TaskCompletion,
            &HookOutcome::Deny {
                message: "run verify".into(),
            },
        );
        assert_eq!(
            (stop_deny.exit_code, stop_deny.stderr.as_str()),
            (0, "run verify")
        );
        let js = parse_json(&stop_deny.stdout).unwrap();
        assert_eq!(
            js.get("decision").and_then(JsonValue::as_str),
            Some("continue")
        );
        assert_eq!(
            js.get("reason").and_then(JsonValue::as_str),
            Some("run verify")
        );
    }
}
