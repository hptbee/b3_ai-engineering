use crate::hook::event::{EventKind, HostId};
use crate::json::JsonValue;

/// Host-neutral evaluation outcome for a hook invocation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HookOutcome {
    Allow,
    Advisory { message: String },
    Deny { message: String },
    Continue { reason: String },
}

/// Host-specific formatted output streams and exit status.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostResponse {
    pub stdout: String,
    pub stderr: String,
    pub exit_code: i32,
}

/// Formats a `HookOutcome` into the exact protocol expected by `host`.
pub fn format_response(
    host: HostId,
    raw_event: &str,
    kind: EventKind,
    outcome: &HookOutcome,
) -> HostResponse {
    match host {
        HostId::Cursor => format_cursor(outcome),
        HostId::Claude | HostId::Codex => format_claude_or_codex(outcome),
        HostId::Antigravity => format_antigravity(raw_event, kind, outcome),
        HostId::Git => format_git(outcome),
    }
}

fn format_cursor(outcome: &HookOutcome) -> HostResponse {
    match outcome {
        HookOutcome::Allow => HostResponse {
            stdout: JsonValue::obj(vec![("permission".into(), JsonValue::str("allow"))])
                .to_json_string(),
            stderr: String::new(),
            exit_code: 0,
        },
        HookOutcome::Advisory { message } => HostResponse {
            stdout: JsonValue::obj(vec![("permission".into(), JsonValue::str("allow"))])
                .to_json_string(),
            stderr: message.clone(),
            exit_code: 0,
        },
        HookOutcome::Deny { message } => HostResponse {
            stdout: JsonValue::obj(vec![
                ("permission".into(), JsonValue::str("deny")),
                ("user_message".into(), JsonValue::str(message)),
                ("agent_message".into(), JsonValue::str(message)),
            ])
            .to_json_string(),
            stderr: message.clone(),
            exit_code: 2,
        },
        HookOutcome::Continue { reason } => HostResponse {
            stdout: JsonValue::obj(vec![("followup_message".into(), JsonValue::str(reason))])
                .to_json_string(),
            stderr: String::new(),
            exit_code: 0,
        },
    }
}

fn format_claude_or_codex(outcome: &HookOutcome) -> HostResponse {
    match outcome {
        HookOutcome::Allow => HostResponse {
            stdout: String::new(),
            stderr: String::new(),
            exit_code: 0,
        },
        HookOutcome::Advisory { message } => HostResponse {
            stdout: String::new(),
            stderr: message.clone(),
            exit_code: 0,
        },
        HookOutcome::Deny { message } => HostResponse {
            stdout: String::new(),
            stderr: message.clone(),
            exit_code: 2,
        },
        HookOutcome::Continue { reason } => HostResponse {
            stdout: String::new(),
            stderr: reason.clone(),
            exit_code: 2,
        },
    }
}

fn format_antigravity(raw_event: &str, kind: EventKind, outcome: &HookOutcome) -> HostResponse {
    let is_pre_tool = matches!(kind, EventKind::BeforeFileWrite | EventKind::BeforeCommand)
        || raw_event == "PreToolUse"
        || raw_event == "PreInvocation";
    let is_stop = matches!(
        kind,
        EventKind::TaskCompletion | EventKind::WorkerCompletion
    ) || raw_event == "Stop";

    if is_stop {
        let stdout = match outcome {
            HookOutcome::Continue { reason } => JsonValue::obj(vec![
                ("decision".into(), JsonValue::str("continue")),
                ("reason".into(), JsonValue::str(reason)),
            ])
            .to_json_string(),
            HookOutcome::Deny { message } => JsonValue::obj(vec![
                ("decision".into(), JsonValue::str("continue")),
                ("reason".into(), JsonValue::str(message)),
            ])
            .to_json_string(),
            HookOutcome::Allow | HookOutcome::Advisory { .. } => "{}".to_string(),
        };
        let stderr = match outcome {
            HookOutcome::Advisory { message } => message.clone(),
            _ => String::new(),
        };
        return HostResponse {
            stdout,
            stderr,
            exit_code: 0,
        };
    }

    if is_pre_tool {
        return match outcome {
            HookOutcome::Allow => HostResponse {
                stdout: JsonValue::obj(vec![("decision".into(), JsonValue::str("allow"))])
                    .to_json_string(),
                stderr: String::new(),
                exit_code: 0,
            },
            HookOutcome::Advisory { message } => HostResponse {
                stdout: JsonValue::obj(vec![("decision".into(), JsonValue::str("allow"))])
                    .to_json_string(),
                stderr: message.clone(),
                exit_code: 0,
            },
            HookOutcome::Deny { message } => HostResponse {
                stdout: JsonValue::obj(vec![
                    ("decision".into(), JsonValue::str("deny")),
                    ("reason".into(), JsonValue::str(message)),
                ])
                .to_json_string(),
                stderr: String::new(),
                exit_code: 0,
            },
            HookOutcome::Continue { reason } => HostResponse {
                stdout: JsonValue::obj(vec![
                    ("decision".into(), JsonValue::str("allow")),
                    ("reason".into(), JsonValue::str(reason)),
                ])
                .to_json_string(),
                stderr: String::new(),
                exit_code: 0,
            },
        };
    }

    // PostToolUse, SessionStart, Unsupported, etc.
    let stderr = match outcome {
        HookOutcome::Advisory { message } | HookOutcome::Deny { message } => message.clone(),
        _ => String::new(),
    };
    HostResponse {
        stdout: "{}".to_string(),
        stderr,
        exit_code: 0,
    }
}

fn format_git(outcome: &HookOutcome) -> HostResponse {
    match outcome {
        HookOutcome::Allow => HostResponse {
            stdout: String::new(),
            stderr: String::new(),
            exit_code: 0,
        },
        HookOutcome::Advisory { message } => HostResponse {
            stdout: String::new(),
            stderr: message.clone(),
            exit_code: 0,
        },
        HookOutcome::Deny { message } => HostResponse {
            stdout: String::new(),
            stderr: message.clone(),
            exit_code: 1,
        },
        HookOutcome::Continue { reason } => HostResponse {
            stdout: String::new(),
            stderr: reason.clone(),
            exit_code: 1,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::json::parse_json;

    #[test]
    fn cursor_responses_match_protocol() {
        let allow = format_response(
            HostId::Cursor,
            "preToolUse",
            EventKind::BeforeFileWrite,
            &HookOutcome::Allow,
        );
        assert_eq!(allow.exit_code, 0);
        let j = parse_json(&allow.stdout).unwrap();
        assert_eq!(j.get("permission").and_then(|v| v.as_str()), Some("allow"));

        let deny = format_response(
            HostId::Cursor,
            "preToolUse",
            EventKind::BeforeCommand,
            &HookOutcome::Deny {
                message: "blocked".to_string(),
            },
        );
        assert_eq!(deny.exit_code, 2);
        assert_eq!(deny.stderr, "blocked");
        let jd = parse_json(&deny.stdout).unwrap();
        assert_eq!(jd.get("permission").and_then(|v| v.as_str()), Some("deny"));
    }

    #[test]
    fn claude_and_codex_responses_match_protocol() {
        for host in [HostId::Claude, HostId::Codex] {
            let adv = format_response(
                host,
                "PreToolUse",
                EventKind::BeforeFileWrite,
                &HookOutcome::Advisory {
                    message: "warn".to_string(),
                },
            );
            assert_eq!(adv.stdout, "");
            assert_eq!(adv.stderr, "warn");
            assert_eq!(adv.exit_code, 0);

            let deny = format_response(
                host,
                "PreToolUse",
                EventKind::BeforeCommand,
                &HookOutcome::Deny {
                    message: "denied".to_string(),
                },
            );
            assert_eq!(deny.stdout, "");
            assert_eq!(deny.stderr, "denied");
            assert_eq!(deny.exit_code, 2);
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
        assert_eq!(pre_allow.exit_code, 0);
        assert_eq!(
            parse_json(&pre_allow.stdout)
                .unwrap()
                .get("decision")
                .and_then(|v| v.as_str()),
            Some("allow")
        );

        let pre_deny = format_response(
            HostId::Antigravity,
            "PreToolUse",
            EventKind::BeforeCommand,
            &HookOutcome::Deny {
                message: "not allowed".to_string(),
            },
        );
        assert_eq!(pre_deny.exit_code, 0);
        let j = parse_json(&pre_deny.stdout).unwrap();
        assert_eq!(j.get("decision").and_then(|v| v.as_str()), Some("deny"));
        assert_eq!(
            j.get("reason").and_then(|v| v.as_str()),
            Some("not allowed")
        );

        let post = format_response(
            HostId::Antigravity,
            "PostToolUse",
            EventKind::AfterFileWrite,
            &HookOutcome::Allow,
        );
        assert_eq!(post.stdout, "{}");
        assert_eq!(post.exit_code, 0);

        let stop_cont = format_response(
            HostId::Antigravity,
            "Stop",
            EventKind::TaskCompletion,
            &HookOutcome::Continue {
                reason: "run verify".to_string(),
            },
        );
        assert_eq!(stop_cont.exit_code, 0);
        let js = parse_json(&stop_cont.stdout).unwrap();
        assert_eq!(
            js.get("decision").and_then(|v| v.as_str()),
            Some("continue")
        );
        assert_eq!(
            js.get("reason").and_then(|v| v.as_str()),
            Some("run verify")
        );

        let stop_allow = format_response(
            HostId::Antigravity,
            "Stop",
            EventKind::TaskCompletion,
            &HookOutcome::Allow,
        );
        assert_eq!(stop_allow.stdout, "{}");
        assert_eq!(stop_allow.exit_code, 0);
    }

    #[test]
    fn git_responses_match_protocol() {
        let allow = format_response(
            HostId::Git,
            "pre-commit",
            EventKind::BeforeCommit,
            &HookOutcome::Allow,
        );
        assert_eq!(allow.exit_code, 0);
        assert_eq!(allow.stdout, "");

        let deny = format_response(
            HostId::Git,
            "pre-push",
            EventKind::BeforePush,
            &HookOutcome::Deny {
                message: "verify required".to_string(),
            },
        );
        assert_eq!(deny.exit_code, 1);
        assert_eq!(deny.stderr, "verify required");
    }
}
