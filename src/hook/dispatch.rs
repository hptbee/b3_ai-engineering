use std::path::{Path, PathBuf};

use crate::adapters::common::normalize_abs_path_str;
use crate::error::{fail, B3Error};
use crate::fs::{
    find_reparse_in_path_hierarchy, has_control_chars, is_reparse_or_symlink, normalize_path_value,
    resolve_safe_repo_write_path, resolve_unresolved_path, split_path_csv_checked,
    test_checkpoint_path, test_path_match, test_secret_path,
};
use crate::git::{is_hex40, run_git, run_git_paths_z, GitZMode};
use crate::guard::{merge_policy, precommit, verify::test_verify_receipt};
use crate::hook::config::{
    default_global_preferences_path, default_project_preferences_path, resolve_hook_config,
    HookConfig, HookConfigOverride, HookMode,
};
use crate::hook::event::{normalize_event, EventKind, HostId, NormalizedEvent};
use crate::hook::response::{format_response, HookOutcome, HostResponse};

fn env_nonempty(name: &str) -> Option<String> {
    std::env::var(name)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

fn env_is_true(name: &str) -> bool {
    env_nonempty(name).is_some_and(|v| v == "1" || v.eq_ignore_ascii_case("true"))
}

fn env_is_one(name: &str) -> bool {
    env_nonempty(name).is_some_and(|v| v == "1")
}

fn is_hook_recursion_active() -> bool {
    env_is_true("B3_HOOK_ACTIVE")
}

fn resolve_lexical_root(raw: &str) -> PathBuf {
    let trimmed = raw.trim();
    let p = Path::new(trimmed);
    let abs = if p.is_absolute() {
        resolve_unresolved_path(p, ".")
    } else if let Ok(cwd) = std::env::current_dir() {
        resolve_unresolved_path(&cwd, trimmed)
    } else {
        PathBuf::from(trimmed)
    };
    PathBuf::from(normalize_abs_path_str(&abs))
}

fn resolve_event_project_root(event: &NormalizedEvent) -> Option<PathBuf> {
    let raw = event
        .project_root
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .or_else(|| {
            event
                .cwd
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
        })?;
    if has_control_chars(raw) {
        return None;
    }
    Some(resolve_lexical_root(raw))
}

fn missing_repo_outcome(context: &str) -> HookOutcome {
    if env_is_one("B3_HOOK_REQUIRE_REPO") {
        HookOutcome::Deny {
            message: format!(
                "HOOK_BLOCKED: {context} requires resolved project_root (B3_HOOK_REQUIRE_REPO=1)"
            ),
        }
    } else {
        HookOutcome::Advisory {
            message: format!(
                "HOOK_ADVISORY: {context} skipped repo-scoped checks (project_root unavailable)"
            ),
        }
    }
}

struct HookActiveEnvGuard {
    prev: Option<std::ffi::OsString>,
}

impl HookActiveEnvGuard {
    fn activate() -> Self {
        let prev = std::env::var_os("B3_HOOK_ACTIVE");
        std::env::set_var("B3_HOOK_ACTIVE", "1");
        Self { prev }
    }
}

impl Drop for HookActiveEnvGuard {
    fn drop(&mut self) {
        match &self.prev {
            Some(v) => std::env::set_var("B3_HOOK_ACTIVE", v),
            None => std::env::remove_var("B3_HOOK_ACTIVE"),
        }
    }
}

/// Formats a fail-closed host response when `b3 hook run` fails before dispatch
/// (e.g., oversized/malformed/control-char payload) and `--host` is recognized.
pub fn fail_closed_host_response(
    host_raw: &str,
    event_hint: Option<&str>,
    message: &str,
) -> Option<HostResponse> {
    let host = HostId::parse(host_raw).ok()?;
    let raw_ev = event_hint.unwrap_or("").trim();
    let kind = match raw_ev {
        "Stop" | "stop" | "SubagentStop" | "subagentStop" => EventKind::TaskCompletion,
        "PostToolUse" | "postToolUse" | "afterFileEdit" | "afterShellExecution" => {
            EventKind::AfterFileWrite
        }
        "pre-commit" => EventKind::BeforeCommit,
        "pre-push" => EventKind::BeforePush,
        "pre-merge-commit" => EventKind::BeforeMerge,
        _ => EventKind::BeforeCommand,
    };
    Some(format_response(
        host,
        raw_ev,
        kind,
        &HookOutcome::Deny {
            message: message.to_string(),
        },
    ))
}

/// Evaluates a raw host hook payload end-to-end and returns the formatted host response
/// alongside the normalized `HookOutcome`.
pub fn run_hook(
    host_raw: &str,
    event_hint: Option<&str>,
    repo_root_raw: Option<&str>,
    mode_override: Option<&str>,
    payload_raw: &str,
) -> Result<(HostResponse, HookOutcome), B3Error> {
    let host = HostId::parse(host_raw)?;
    let mode_ov = match mode_override.map(str::trim).filter(|s| !s.is_empty()) {
        Some(raw) => Some(HookMode::parse(raw)?),
        None => None,
    };

    if is_hook_recursion_active() {
        let (raw_ev, kind) = match normalize_event(host, event_hint, payload_raw, repo_root_raw) {
            Ok(ev) => (ev.raw_event_name, ev.event),
            Err(_) => (
                event_hint.unwrap_or("").trim().to_string(),
                EventKind::Unsupported,
            ),
        };
        let outcome = HookOutcome::Allow;
        let resp = format_response(host, &raw_ev, kind, &outcome);
        return Ok((resp, outcome));
    }

    let explicit_repo = repo_root_raw.map(str::trim).filter(|s| !s.is_empty());
    if let Some(r) = explicit_repo {
        if has_control_chars(r) {
            return Err(fail(
                "HOOK_INVALID_FIELD: control characters rejected in repo_root",
                1,
            ));
        }
    }

    let cwd_fallback = std::env::current_dir()
        .ok()
        .map(|p| p.to_string_lossy().into_owned());
    let default_cwd = explicit_repo.or(cwd_fallback.as_deref());

    let mut event = normalize_event(host, event_hint, payload_raw, default_cwd)?;
    // Explicit --repo-root always takes precedence over untrusted payload metadata.
    if let Some(r) = explicit_repo {
        event.project_root = Some(r.to_string());
    }

    let root_for_cfg = explicit_repo
        .or(event.project_root.as_deref())
        .or(event.cwd.as_deref());
    let project_pref =
        root_for_cfg.map(|r| default_project_preferences_path(&resolve_lexical_root(r)));
    let global_pref = default_global_preferences_path(None);
    let cli_ov = mode_ov.map(|m| HookConfigOverride {
        enabled: None,
        mode: Some(m),
    });
    let (cfg, _warnings) = resolve_hook_config(project_pref.as_deref(), Some(&global_pref), cli_ov);

    let _active_guard = HookActiveEnvGuard::activate();
    let outcome = dispatch_event_inner(&event, &cfg);
    let resp = format_response(host, &event.raw_event_name, event.event, &outcome);
    Ok((resp, outcome))
}

/// Evaluates a normalized hook event against `cfg` without host-specific serialization.
pub fn dispatch_event(event: &NormalizedEvent, cfg: &HookConfig) -> HookOutcome {
    if is_hook_recursion_active() || cfg.effective_mode() == HookMode::Off {
        return HookOutcome::Allow;
    }
    let _active_guard = HookActiveEnvGuard::activate();
    dispatch_event_inner(event, cfg)
}

fn dispatch_event_inner(event: &NormalizedEvent, cfg: &HookConfig) -> HookOutcome {
    if cfg.effective_mode() == HookMode::Off {
        return HookOutcome::Allow;
    }

    let raw = match event.event {
        EventKind::BeforeFileWrite => eval_before_file_write(event),
        EventKind::BeforeCommand => eval_before_command(event),
        EventKind::BeforeCommit => eval_before_commit(event),
        EventKind::BeforePush | EventKind::BeforeMerge => eval_before_push_or_merge(event),
        EventKind::AfterFileWrite => eval_after_file_write(event),
        EventKind::WorkerCompletion | EventKind::TaskCompletion => eval_completion(event),
        EventKind::SessionStart
        | EventKind::AfterCommand
        | EventKind::SessionEnd
        | EventKind::Unsupported => HookOutcome::Allow,
    };

    if cfg.mode == HookMode::Audit {
        if let HookOutcome::Deny { message } = raw {
            return HookOutcome::Advisory {
                message: format!("[audit] {message}"),
            };
        }
    }
    raw
}

fn is_git_internal_path(rel_slash: &str) -> bool {
    rel_slash
        .split('/')
        .any(|seg| seg.eq_ignore_ascii_case(".git"))
}

fn is_ship_evidence_path(rel_slash: &str) -> bool {
    let segs: Vec<&str> = rel_slash.split('/').collect();
    segs.len() >= 5
        && segs[0].eq_ignore_ascii_case(".b3")
        && segs[1].eq_ignore_ascii_case("ship")
        && segs[2].eq_ignore_ascii_case("runs")
        && !segs[3].is_empty()
        && segs[4].eq_ignore_ascii_case("evidence")
}

fn parse_optional_env_paths(env_name: &str) -> Result<Option<Vec<String>>, B3Error> {
    let Some(raw) = env_nonempty(env_name) else {
        return Ok(None);
    };
    let parsed = split_path_csv_checked(&raw, "HOOK_BLOCKED", false, None)?;
    Ok(Some(parsed))
}

fn eval_before_file_write(event: &NormalizedEvent) -> HookOutcome {
    let Some(root) = resolve_event_project_root(event) else {
        return missing_repo_outcome("BeforeFileWrite");
    };
    if event.affected_paths.is_empty() {
        return HookOutcome::Allow;
    }

    if is_reparse_or_symlink(&root) {
        return HookOutcome::Deny {
            message: format!(
                "HOOK_BLOCKED: project_root is a symlink or reparse point: {}",
                root.display()
            ),
        };
    }

    let root_has_reparse_ancestor = find_reparse_in_path_hierarchy(&root).is_some();

    let protected_env = match parse_optional_env_paths("B3_PROTECTED_PATHS") {
        Ok(v) => v.unwrap_or_default(),
        Err(e) => return HookOutcome::Deny { message: e.message },
    };
    let worker_allowed = match parse_optional_env_paths("B3_WORKER_ALLOWED_PATHS") {
        Ok(v) => v,
        Err(e) => return HookOutcome::Deny { message: e.message },
    };

    for raw_path in &event.affected_paths {
        let Some((full, rel)) = resolve_safe_repo_write_path(&root, raw_path) else {
            let norm_raw = normalize_path_value(raw_path);
            let msg = if is_git_internal_path(&norm_raw) {
                format!("HOOK_BLOCKED: protected path '.git' cannot be modified: {raw_path}")
            } else {
                format!(
                    "HOOK_BLOCKED: unsafe write path (outside project_root, traversal, or symlink/reparse): {raw_path}"
                )
            };
            return HookOutcome::Deny { message: msg };
        };

        if !root_has_reparse_ancestor {
            if let Some(rep) = find_reparse_in_path_hierarchy(&full) {
                return HookOutcome::Deny {
                    message: format!(
                        "HOOK_BLOCKED: symlink or reparse point in path hierarchy: {}",
                        rep.display()
                    ),
                };
            }
        }
        if is_reparse_or_symlink(&full) {
            return HookOutcome::Deny {
                message: format!("HOOK_BLOCKED: target is a symlink or reparse point: {rel}"),
            };
        }

        if is_git_internal_path(&rel) {
            return HookOutcome::Deny {
                message: format!("HOOK_BLOCKED: protected path '.git': {rel}"),
            };
        }
        if is_ship_evidence_path(&rel) {
            return HookOutcome::Deny {
                message: format!("HOOK_BLOCKED: protected ship evidence path: {rel}"),
            };
        }
        if rel.eq_ignore_ascii_case(".b3/research-policy.json") {
            return HookOutcome::Deny {
                message: format!("HOOK_BLOCKED: protected research policy path: {rel}"),
            };
        }
        if test_secret_path(&rel) {
            return HookOutcome::Deny {
                message: format!("HOOK_BLOCKED: protected secret path: {rel}"),
            };
        }
        if !protected_env.is_empty() && test_path_match(&rel, &protected_env) {
            return HookOutcome::Deny {
                message: format!("HOOK_BLOCKED: protected path (B3_PROTECTED_PATHS): {rel}"),
            };
        }
        if let Some(ref allowed) = worker_allowed {
            if !test_path_match(&rel, allowed) {
                return HookOutcome::Deny {
                    message: format!("HOOK_BLOCKED: write outside B3_WORKER_ALLOWED_PATHS: {rel}"),
                };
            }
        }
    }

    HookOutcome::Allow
}

fn tokenize_shell_segments(cmd: &str) -> Vec<Vec<String>> {
    let chars: Vec<char> = cmd.chars().collect();
    let len = chars.len();
    let mut i = 0usize;

    let mut segments: Vec<Vec<String>> = Vec::new();
    let mut cur_seg: Vec<String> = Vec::new();
    let mut cur_tok = String::new();
    let mut in_tok = false;
    let mut in_single = false;
    let mut in_double = false;

    let flush_tok = |tok: &mut String, in_t: &mut bool, seg: &mut Vec<String>| {
        if *in_t {
            seg.push(std::mem::take(tok));
            *in_t = false;
        }
    };
    let flush_seg =
        |tok: &mut String, in_t: &mut bool, seg: &mut Vec<String>, segs: &mut Vec<Vec<String>>| {
            flush_tok(tok, in_t, seg);
            if !seg.is_empty() {
                segs.push(std::mem::take(seg));
            }
        };

    while i < len {
        let ch = chars[i];
        if in_single {
            if ch == '\'' {
                in_single = false;
            } else {
                cur_tok.push(ch);
            }
            i += 1;
            continue;
        }

        if in_double {
            if ch == '\\' && i + 1 < len {
                let next = chars[i + 1];
                if matches!(next, '"' | '\\' | '$' | '`' | '\n') {
                    if next != '\n' {
                        cur_tok.push(next);
                    }
                    i += 2;
                    continue;
                }
            }
            if ch == '"' {
                in_double = false;
            } else {
                cur_tok.push(ch);
            }
            i += 1;
            continue;
        }

        // Unquoted context
        match ch {
            ' ' | '\t' | '\r' => {
                flush_tok(&mut cur_tok, &mut in_tok, &mut cur_seg);
                i += 1;
            }
            '\n' | ';' | '(' | ')' => {
                flush_seg(&mut cur_tok, &mut in_tok, &mut cur_seg, &mut segments);
                i += 1;
            }
            '|' => {
                flush_seg(&mut cur_tok, &mut in_tok, &mut cur_seg, &mut segments);
                if i + 1 < len && chars[i + 1] == '|' {
                    i += 2;
                } else {
                    i += 1;
                }
            }
            '&' => {
                // Keep fd redirections like `2>&1`, `>&2`, `<&0` inside the token/ignored.
                let is_redir = i > 0 && matches!(chars[i - 1], '>' | '<');
                if is_redir {
                    cur_tok.push('&');
                    in_tok = true;
                    i += 1;
                } else {
                    flush_seg(&mut cur_tok, &mut in_tok, &mut cur_seg, &mut segments);
                    if i + 1 < len && chars[i + 1] == '&' {
                        i += 2;
                    } else {
                        i += 1;
                    }
                }
            }
            '#' if !in_tok => {
                // Shell comment until newline
                while i < len && chars[i] != '\n' {
                    i += 1;
                }
            }
            '\'' => {
                in_single = true;
                in_tok = true;
                i += 1;
            }
            '"' => {
                in_double = true;
                in_tok = true;
                i += 1;
            }
            '\\' if i + 1 < len => {
                let next = chars[i + 1];
                if next != '\n' {
                    cur_tok.push(next);
                    in_tok = true;
                }
                i += 2;
            }
            _ => {
                cur_tok.push(ch);
                in_tok = true;
                i += 1;
            }
        }
    }

    flush_seg(&mut cur_tok, &mut in_tok, &mut cur_seg, &mut segments);
    segments
}

fn is_env_assignment(tok: &str) -> bool {
    let Some((name, _val)) = tok.split_once('=') else {
        return false;
    };
    let mut chars = name.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    (first.is_ascii_alphabetic() || first == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

fn strip_command_wrappers(mut seg: &[String]) -> &[String] {
    loop {
        while let Some(first) = seg.first() {
            if is_env_assignment(first) {
                seg = &seg[1..];
            } else {
                break;
            }
        }
        let Some(first) = seg.first() else {
            return seg;
        };
        let base = command_basename(first);
        match base.as_str() {
            "command" | "exec" | "nohup" | "time" => {
                seg = &seg[1..];
                while let Some(arg) = seg.first() {
                    if arg.starts_with('-') && arg != "--" {
                        seg = &seg[1..];
                    } else {
                        if arg == "--" {
                            seg = &seg[1..];
                        }
                        break;
                    }
                }
            }
            "env" => {
                seg = &seg[1..];
                while let Some(arg) = seg.first() {
                    if arg == "--" {
                        seg = &seg[1..];
                        break;
                    }
                    if arg == "-u" || arg == "--unset" || arg == "-C" || arg == "--chdir" {
                        seg = if seg.len() >= 2 { &seg[2..] } else { &[] };
                    } else if arg.starts_with('-') || is_env_assignment(arg) {
                        seg = &seg[1..];
                    } else {
                        break;
                    }
                }
            }
            _ => return seg,
        }
    }
}

fn command_basename(raw: &str) -> String {
    let leaf = raw.rsplit(['/', '\\']).next().unwrap_or(raw);
    let lower = leaf.to_ascii_lowercase();
    for ext in [".exe", ".cmd", ".bat"] {
        if let Some(stripped) = lower.strip_suffix(ext) {
            return stripped.to_string();
        }
    }
    lower
}

fn parse_git_subcommand(args: &[String]) -> Option<(&str, &[String])> {
    let mut i = 0usize;
    while i < args.len() {
        let a = args[i].as_str();
        if !a.starts_with('-') {
            return Some((a, &args[i + 1..]));
        }
        if matches!(
            a,
            "-C" | "-c"
                | "--git-dir"
                | "--work-tree"
                | "--namespace"
                | "--super-prefix"
                | "--config-env"
                | "--exec-path"
        ) {
            i += 2;
            continue;
        }
        if a == "--" {
            return None;
        }
        i += 1;
    }
    None
}

fn short_cluster_has_before_value(arg: &str, needle: char, value_flags: &[char]) -> bool {
    if !arg.starts_with('-') || arg.starts_with("--") || arg.len() < 2 {
        return false;
    }
    for ch in arg[1..].chars() {
        if ch == needle {
            return true;
        }
        if value_flags.contains(&ch) {
            return false;
        }
    }
    false
}

fn short_cluster_ends_with_value_flag(arg: &str, value_flags: &[char]) -> bool {
    if !arg.starts_with('-') || arg.starts_with("--") || arg.len() < 2 {
        return false;
    }
    arg[1..]
        .chars()
        .last()
        .is_some_and(|ch| value_flags.contains(&ch))
}

fn is_git_push_forced(args: &[String]) -> bool {
    for arg in args {
        if arg == "--" {
            break;
        }
        if arg == "--force" {
            return true;
        }
        if short_cluster_has_before_value(arg, 'f', &['o', 'C']) {
            return true;
        }
    }
    false
}

fn is_git_reset_hard(args: &[String]) -> bool {
    for arg in args {
        if arg == "--" {
            break;
        }
        if arg == "--hard" {
            return true;
        }
    }
    false
}

fn is_git_commit_no_verify(args: &[String]) -> bool {
    let value_long = [
        "-m",
        "--message",
        "-F",
        "--file",
        "-C",
        "--reuse-message",
        "-c",
        "--reedit-message",
        "--fixup",
        "--squash",
        "--author",
        "--date",
        "--cleanup",
        "-u",
        "--untracked-files",
        "--pathspec-from-file",
        "-t",
        "--template",
        "-S",
        "--gpg-sign",
    ];
    let value_short = ['m', 'F', 'C', 'c', 't', 'u', 'S'];
    let mut skip_next = false;

    for arg in args {
        if skip_next {
            skip_next = false;
            continue;
        }
        if arg == "--" {
            break;
        }
        if arg == "--no-verify" {
            return true;
        }
        if value_long.contains(&arg.as_str()) {
            skip_next = true;
            continue;
        }
        if arg.starts_with('-') && !arg.starts_with("--") {
            if short_cluster_has_before_value(arg, 'n', &value_short) {
                return true;
            }
            if short_cluster_ends_with_value_flag(arg, &value_short) {
                skip_next = true;
            }
        }
    }
    false
}

fn check_git_add_command(args: &[String], project_root: Option<&Path>) -> Option<String> {
    let mut has_all_flag = false;
    let mut after_double_dash = false;
    let mut skip_next = false;
    let mut pathspecs: Vec<&str> = Vec::new();

    for arg in args {
        if skip_next {
            skip_next = false;
            continue;
        }
        if !after_double_dash && arg == "--" {
            after_double_dash = true;
            continue;
        }
        if !after_double_dash && arg.starts_with('-') {
            if arg == "--all" || short_cluster_has_before_value(arg, 'A', &[]) {
                has_all_flag = true;
            } else if matches!(arg.as_str(), "--chmod" | "--pathspec-from-file") {
                skip_next = true;
            }
            continue;
        }
        pathspecs.push(arg.as_str());
    }

    let mut has_dot_pathspec = false;
    for ps in &pathspecs {
        let trimmed = ps.trim_end_matches(['/', '\\']);
        let norm = normalize_path_value(if trimmed.is_empty() { ps } else { trimmed });
        let norm_low = norm.to_ascii_lowercase();
        if norm_low == "." || norm_low == "./" {
            has_dot_pathspec = true;
        }
        if norm_low == ".b3"
            || norm_low == ".b3/ship"
            || norm_low.starts_with(".b3/ship/")
            || norm_low == ".b3/research-ship"
            || norm_low.starts_with(".b3/research-ship/")
            || test_checkpoint_path(&norm)
        {
            return Some(format!(
                "HOOK_BLOCKED: staging B3 checkpoint path is blocked: {ps}"
            ));
        }
    }

    if (has_all_flag || has_dot_pathspec)
        && project_root.is_some_and(|root| root.join(".b3").is_dir())
    {
        return Some(
            "HOOK_BLOCKED: 'git add -A' / 'git add .' is blocked when .b3/ exists (stage explicit paths instead)".to_string(),
        );
    }

    None
}

fn is_gh_pr_merge(args: &[String]) -> bool {
    let mut non_flags: Vec<&str> = Vec::new();
    let mut skip_next = false;
    for arg in args {
        if skip_next {
            skip_next = false;
            continue;
        }
        if arg == "--" {
            break;
        }
        if matches!(arg.as_str(), "-R" | "--repo" | "-h" | "--hostname") {
            skip_next = true;
            continue;
        }
        if arg.starts_with('-') {
            continue;
        }
        non_flags.push(arg.as_str());
        if non_flags.len() >= 2 {
            break;
        }
    }
    non_flags.len() >= 2 && non_flags[0] == "pr" && non_flags[1] == "merge"
}

fn eval_before_command(event: &NormalizedEvent) -> HookOutcome {
    let Some(cmd_raw) = event.command.as_deref() else {
        return HookOutcome::Allow;
    };
    if cmd_raw.trim().is_empty() {
        return HookOutcome::Allow;
    }

    let project_root = resolve_event_project_root(event);
    let segments = tokenize_shell_segments(cmd_raw);

    for seg in &segments {
        let stripped = strip_command_wrappers(seg);
        let Some((prog_raw, args)) = stripped.split_first() else {
            continue;
        };
        let prog = command_basename(prog_raw);

        if prog == "git" {
            let Some((subcmd, sub_args)) = parse_git_subcommand(args) else {
                continue;
            };
            match subcmd {
                "push" if is_git_push_forced(sub_args) => {
                    return HookOutcome::Deny {
                        message: "HOOK_BLOCKED: 'git push --force' / '-f' is blocked (use --force-with-lease if intentional)".to_string(),
                    };
                }
                "reset" if is_git_reset_hard(sub_args) => {
                    return HookOutcome::Deny {
                        message: "HOOK_BLOCKED: 'git reset --hard' is blocked".to_string(),
                    };
                }
                "commit" if is_git_commit_no_verify(sub_args) => {
                    return HookOutcome::Deny {
                        message: "HOOK_BLOCKED: 'git commit --no-verify' / '-n' is blocked"
                            .to_string(),
                    };
                }
                "add" => {
                    if let Some(msg) = check_git_add_command(sub_args, project_root.as_deref()) {
                        return HookOutcome::Deny { message: msg };
                    }
                }
                _ => {}
            }
        } else if prog == "gh" && is_gh_pr_merge(args) && !env_is_one("B3_MERGE_AUTHORIZED") {
            return HookOutcome::Deny {
                message: "HOOK_BLOCKED: 'gh pr merge' requires B3_MERGE_AUTHORIZED=1".to_string(),
            };
        }
    }

    HookOutcome::Allow
}

fn eval_before_commit(event: &NormalizedEvent) -> HookOutcome {
    let Some(root) = resolve_event_project_root(event) else {
        return missing_repo_outcome("BeforeCommit");
    };
    let root_str = root.to_string_lossy().into_owned();
    let hook_env: [(&str, &str); 1] = [("B3_HOOK_ACTIVE", "1")];

    if env_is_one("B3_HOOK_SKIP_PRECOMMIT") {
        if let Some(verified_tree) = env_nonempty("B3_PRECOMMIT_VERIFIED_TREE") {
            let verified_low = verified_tree.to_ascii_lowercase();
            if is_hex40(&verified_low) {
                if let Ok(wt) = run_git(&root, &["write-tree"], &hook_env, None) {
                    if wt.exit_code == 0 {
                        let cur_tree = String::from_utf8_lossy(&wt.stdout)
                            .trim()
                            .to_ascii_lowercase();
                        if cur_tree == verified_low {
                            return HookOutcome::Allow;
                        }
                    }
                }
            }
        }
    }

    let receipt = env_nonempty("B3_VERIFY_RECEIPT").unwrap_or_default();
    let ignore_dirty = env_nonempty("B3_IGNORE_DIRTY_PATHS").unwrap_or_default();
    let expected_cmd = env_nonempty("B3_EXPECTED_CMD").unwrap_or_default();
    let relevant_paths = env_nonempty("B3_RELEVANT_PATHS").unwrap_or_default();

    let allowed_paths = if let Some(explicit_allowed) = env_nonempty("B3_ALLOWED_PATHS") {
        explicit_allowed
    } else {
        let staged = match run_git_paths_z(
            &root,
            &[
                "diff",
                "--no-ext-diff",
                "--no-renames",
                "--cached",
                "--name-only",
                "-z",
                "--",
            ],
            GitZMode::Names,
            "PRECOMMIT_FAIL",
            &hook_env,
        ) {
            Ok(s) => s,
            Err(e) => return HookOutcome::Deny { message: e.message },
        };

        if staged.is_empty() {
            String::new()
        } else {
            let safe_staged: Vec<String> = staged
                .into_iter()
                .filter(|p| {
                    !test_checkpoint_path(p)
                        && !test_secret_path(p)
                        && !p.contains([',', '*', '?', ':'])
                })
                .collect();
            if safe_staged.is_empty() {
                // Ensure `precommit::run` reaches checkpoint & secret diagnostics cleanly
                // instead of stopping early on `missing --allowed-paths`.
                "__b3_no_allowed_paths__".to_string()
            } else {
                safe_staged.join(",")
            }
        }
    };

    match precommit::run(
        &root_str,
        &allowed_paths,
        &receipt,
        &ignore_dirty,
        &expected_cmd,
        &relevant_paths,
    ) {
        Ok(_) => HookOutcome::Allow,
        Err(e) => HookOutcome::Deny { message: e.message },
    }
}

fn eval_before_push_or_merge(event: &NormalizedEvent) -> HookOutcome {
    let Some(root) = resolve_event_project_root(event) else {
        return missing_repo_outcome(event.event.as_str());
    };
    let policy_file = root.join(".b3").join("research-policy.json");
    if !policy_file.exists() && !is_reparse_or_symlink(&policy_file) {
        return HookOutcome::Allow;
    }

    let root_str = root.to_string_lossy().into_owned();
    let policy_path = env_nonempty("B3_MERGE_POLICY_PATH").unwrap_or_default();
    let pr_state = env_nonempty("B3_PR_STATE");
    let ci_status = env_nonempty("B3_CI_STATUS");
    let review_status = env_nonempty("B3_REVIEW_STATUS");
    let blocking_findings = env_nonempty("B3_BLOCKING_FINDINGS")
        .and_then(|s| s.parse::<i32>().ok())
        .unwrap_or(0);
    let governance_status = env_nonempty("B3_GOVERNANCE_STATUS").unwrap_or_default();
    let changed_paths = env_nonempty("B3_CHANGED_PATHS").unwrap_or_default();
    let main_ref = env_nonempty("B3_MAIN_REF").unwrap_or_default();
    let target_ref = env_nonempty("B3_TARGET_REF").unwrap_or_default();
    let authority_ref = env_nonempty("B3_AUTHORITY_REF").unwrap_or_default();
    let base_sha = env_nonempty("B3_BASE_SHA").unwrap_or_default();
    let head_sha = env_nonempty("B3_HEAD_SHA").unwrap_or_default();
    let ledger_path = env_nonempty("B3_LEDGER_PATH").unwrap_or_default();
    let receipt_path = env_nonempty("B3_VERIFY_RECEIPT").unwrap_or_default();
    let ignore_dirty = env_nonempty("B3_IGNORE_DIRTY_PATHS").unwrap_or_default();
    let pr_number = env_nonempty("B3_PR_NUMBER").unwrap_or_default();
    let repo_arg = env_nonempty("B3_REPO").unwrap_or_default();
    let target_branch = env_nonempty("B3_TARGET_BRANCH").unwrap_or_default();
    let local_only = env_is_true("B3_LOCAL_ONLY");
    let require_remote_ci = env_is_true("B3_REQUIRE_REMOTE_CI");

    match merge_policy::run(
        &root_str,
        &policy_path,
        pr_state.as_deref(),
        ci_status.as_deref(),
        review_status.as_deref(),
        blocking_findings,
        &governance_status,
        &changed_paths,
        false,
        "",
        &main_ref,
        &target_ref,
        &authority_ref,
        &base_sha,
        &head_sha,
        &ledger_path,
        &receipt_path,
        &ignore_dirty,
        &pr_number,
        &repo_arg,
        &target_branch,
        local_only,
        require_remote_ci,
    ) {
        Ok((_, 0)) => HookOutcome::Allow,
        Ok((msg, _)) => HookOutcome::Deny { message: msg },
        Err(e) => HookOutcome::Deny { message: e.message },
    }
}

fn check_receipt_advisory(root: &Path, receipt_path: &str, edited_paths: &[String]) -> HookOutcome {
    let ignored = env_nonempty("B3_IGNORE_DIRTY_PATHS")
        .and_then(|csv| split_path_csv_checked(&csv, "HOOK_ADVISORY", true, None).ok())
        .unwrap_or_default();
    let vr = test_verify_receipt(root, receipt_path, &ignored, "", "", "");
    if vr.code != 0 {
        return HookOutcome::Advisory {
            message: format!(
                "HOOK_ADVISORY: verification receipt '{}' is not fresh ({}); re-verify before commit",
                receipt_path, vr.message
            ),
        };
    }

    if !edited_paths.is_empty() {
        let rel_paths: Vec<String> = edited_paths
            .iter()
            .filter_map(|p| resolve_safe_repo_write_path(root, p).map(|(_, rel)| rel))
            .collect();
        let rec_scope = vr.relevant_paths_csv.trim();
        let covered = if rec_scope == "ALL" {
            !rel_paths.is_empty()
        } else {
            let patterns = crate::fs::split_csv_list_as_paths(rec_scope);
            rel_paths.iter().any(|p| test_path_match(p, &patterns))
        };
        if covered {
            return HookOutcome::Advisory {
                message: format!(
                    "HOOK_ADVISORY: edited file(s) fall within verification receipt '{}' scope; re-verify if behavior changed",
                    receipt_path
                ),
            };
        }
    }

    HookOutcome::Allow
}

fn eval_after_file_write(event: &NormalizedEvent) -> HookOutcome {
    let Some(receipt_path) = env_nonempty("B3_VERIFY_RECEIPT") else {
        return HookOutcome::Allow;
    };
    let Some(root) = resolve_event_project_root(event) else {
        return HookOutcome::Allow;
    };
    check_receipt_advisory(&root, &receipt_path, &event.affected_paths)
}

fn eval_completion(event: &NormalizedEvent) -> HookOutcome {
    if event.continuation_active {
        return HookOutcome::Allow;
    }
    let Some(receipt_path) = env_nonempty("B3_VERIFY_RECEIPT") else {
        return HookOutcome::Allow;
    };
    let Some(root) = resolve_event_project_root(event) else {
        return HookOutcome::Allow;
    };
    let ignored = env_nonempty("B3_IGNORE_DIRTY_PATHS")
        .and_then(|csv| split_path_csv_checked(&csv, "HOOK_ADVISORY", true, None).ok())
        .unwrap_or_default();
    let vr = test_verify_receipt(&root, &receipt_path, &ignored, "", "", "");
    if vr.code != 0 {
        HookOutcome::Advisory {
            message: format!(
                "HOOK_ADVISORY: verification receipt '{}' is not fresh ({})",
                receipt_path, vr.message
            ),
        }
    } else {
        HookOutcome::Allow
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fs::next_tmp_suffix;
    use crate::git::run_git;
    use crate::json::parse_json;
    use std::fs;

    fn lock_hook_env() -> std::sync::MutexGuard<'static, ()> {
        crate::hook::HOOK_ENV_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner())
    }

    struct EnvGuard {
        saved: Vec<(&'static str, Option<String>)>,
    }

    impl EnvGuard {
        fn new(vars: &[(&'static str, Option<&str>)]) -> Self {
            let mut saved = Vec::with_capacity(vars.len());
            for &(k, v) in vars {
                saved.push((k, std::env::var(k).ok()));
                match v {
                    Some(val) => std::env::set_var(k, val),
                    None => std::env::remove_var(k),
                }
            }
            Self { saved }
        }
    }

    impl Drop for EnvGuard {
        fn drop(&mut self) {
            for (k, prev) in self.saved.drain(..).rev() {
                match prev {
                    Some(v) => std::env::set_var(k, v),
                    None => std::env::remove_var(k),
                }
            }
        }
    }

    fn clear_hook_env() -> EnvGuard {
        EnvGuard::new(&[
            ("B3_HOOK_ACTIVE", None),
            ("B3_HOOK_MODE", None),
            ("B3_HOOK_REQUIRE_REPO", None),
            ("B3_PROTECTED_PATHS", None),
            ("B3_WORKER_ALLOWED_PATHS", None),
            ("B3_MERGE_AUTHORIZED", None),
            ("B3_HOOK_SKIP_PRECOMMIT", None),
            ("B3_PRECOMMIT_VERIFIED_TREE", None),
            ("B3_ALLOWED_PATHS", None),
            ("B3_VERIFY_RECEIPT", None),
            ("B3_IGNORE_DIRTY_PATHS", None),
            ("B3_EXPECTED_CMD", None),
            ("B3_RELEVANT_PATHS", None),
            ("B3_MODELS_PERSONAL", None),
        ])
    }

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("b3_hook_disp_{name}_{}", next_tmp_suffix()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn make_write_event(root: Option<&str>, paths: &[&str]) -> NormalizedEvent {
        NormalizedEvent {
            host: HostId::Cursor,
            event: EventKind::BeforeFileWrite,
            raw_event_name: "preToolUse".to_string(),
            project_root: root.map(str::to_string),
            cwd: root.map(str::to_string),
            session_id: None,
            worker_id: None,
            run_id: None,
            operation_id: None,
            tool_name: Some("Write".to_string()),
            affected_paths: paths.iter().map(|s| (*s).to_string()).collect(),
            command: None,
            continuation_active: false,
            state_fingerprint: None,
        }
    }

    fn make_cmd_event(root: Option<&str>, cmd: &str) -> NormalizedEvent {
        NormalizedEvent {
            host: HostId::Cursor,
            event: EventKind::BeforeCommand,
            raw_event_name: "beforeShellExecution".to_string(),
            project_root: root.map(str::to_string),
            cwd: root.map(str::to_string),
            session_id: None,
            worker_id: None,
            run_id: None,
            operation_id: None,
            tool_name: Some("Shell".to_string()),
            affected_paths: Vec::new(),
            command: Some(cmd.to_string()),
            continuation_active: false,
            state_fingerprint: None,
        }
    }

    #[test]
    fn recursion_guard_and_off_mode_allow_immediately() {
        let _lock = lock_hook_env();
        let _env = clear_hook_env();

        let dir = temp_dir("recursion");
        let deny_ev = make_write_event(Some(&dir.to_string_lossy()), &[".git/config"]);
        assert!(matches!(
            dispatch_event(&deny_ev, &HookConfig::default()),
            HookOutcome::Deny { .. }
        ));

        {
            let _rec = EnvGuard::new(&[("B3_HOOK_ACTIVE", Some("1"))]);
            assert_eq!(
                dispatch_event(&deny_ev, &HookConfig::default()),
                HookOutcome::Allow
            );
            let payload = r#"{"hookEventName":"PreToolUse","toolCall":{"name":"run_command","args":{"CommandLine":"git push --force"}}}"#;
            let (resp, out) = run_hook("antigravity", None, None, None, payload).unwrap();
            assert_eq!(out, HookOutcome::Allow);
            assert_eq!(
                parse_json(&resp.stdout)
                    .unwrap()
                    .get("decision")
                    .and_then(|v| v.as_str()),
                Some("allow")
            );
        }

        let off_cfg = HookConfig {
            enabled: false,
            mode: HookMode::Enforce,
        };
        assert_eq!(dispatch_event(&deny_ev, &off_cfg), HookOutcome::Allow);

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn before_file_write_enforces_containment_protected_and_ownership() {
        let _lock = lock_hook_env();
        let _env = clear_hook_env();
        let cfg = HookConfig::default();

        // Missing project_root -> advisory by default, deny when B3_HOOK_REQUIRE_REPO=1
        let no_root = make_write_event(None, &["src/lib.rs"]);
        assert!(matches!(
            dispatch_event(&no_root, &cfg),
            HookOutcome::Advisory { .. }
        ));
        {
            let _req = EnvGuard::new(&[("B3_HOOK_REQUIRE_REPO", Some("1"))]);
            assert!(matches!(
                dispatch_event(&no_root, &cfg),
                HookOutcome::Deny { .. }
            ));
        }

        let root = temp_dir("write_rules");
        let root_str = root.to_string_lossy().into_owned();
        let outside = temp_dir("outside");
        let outside_file = outside.join("escape.txt").to_string_lossy().into_owned();

        // Normal file allowed
        assert_eq!(
            dispatch_event(&make_write_event(Some(&root_str), &["src/main.rs"]), &cfg),
            HookOutcome::Allow
        );

        // Traversal, absolute outside, protected paths, secrets
        for blocked in [
            "../outside.txt",
            "src/../../outside.txt",
            &outside_file,
            ".git/config",
            ".git/hooks/pre-commit",
            ".b3/ship/runs/run-1/evidence/verify.txt",
            ".b3/research-policy.json",
            ".env",
            ".env.local",
            "keys/id_rsa",
            "certs/server.pem",
        ] {
            let out = dispatch_event(&make_write_event(Some(&root_str), &[blocked]), &cfg);
            assert!(
                matches!(out, HookOutcome::Deny { .. }),
                "expected Deny for {blocked}, got {out:?}"
            );
        }

        // .env.example allowed
        assert_eq!(
            dispatch_event(&make_write_event(Some(&root_str), &[".env.example"]), &cfg),
            HookOutcome::Allow
        );

        // B3_PROTECTED_PATHS and B3_WORKER_ALLOWED_PATHS
        {
            let _g = EnvGuard::new(&[
                ("B3_PROTECTED_PATHS", Some("Cargo.lock,infra")),
                ("B3_WORKER_ALLOWED_PATHS", Some("src/hook,tests")),
            ]);
            assert!(matches!(
                dispatch_event(&make_write_event(Some(&root_str), &["Cargo.lock"]), &cfg),
                HookOutcome::Deny { .. }
            ));
            assert!(matches!(
                dispatch_event(&make_write_event(Some(&root_str), &["src/lib.rs"]), &cfg),
                HookOutcome::Deny { .. }
            ));
            assert_eq!(
                dispatch_event(
                    &make_write_event(Some(&root_str), &["src/hook/dispatch.rs"]),
                    &cfg
                ),
                HookOutcome::Allow
            );
        }

        // Audit mode converts Deny to [audit] Advisory
        let audit_cfg = HookConfig {
            enabled: true,
            mode: HookMode::Audit,
        };
        let audit_out = dispatch_event(
            &make_write_event(Some(&root_str), &[".git/config"]),
            &audit_cfg,
        );
        match audit_out {
            HookOutcome::Advisory { message } => assert!(message.starts_with("[audit] ")),
            other => panic!("expected Advisory, got {other:?}"),
        }

        let _ = fs::remove_dir_all(&root);
        let _ = fs::remove_dir_all(&outside);
    }

    #[test]
    fn before_file_write_blocks_symlinks_or_junctions() {
        let _lock = lock_hook_env();
        let _env = clear_hook_env();

        let root = temp_dir("reparse_root");
        let outside = temp_dir("reparse_outside");
        let link = root.join("linked_dir");

        if crate::adapters::common::create_dir_link(&link, &outside).is_ok() {
            let root_str = root.to_string_lossy().into_owned();
            let out = dispatch_event(
                &make_write_event(Some(&root_str), &["linked_dir/file.txt"]),
                &HookConfig::default(),
            );
            assert!(
                matches!(out, HookOutcome::Deny { .. }),
                "expected symlink/junction write to be denied, got {out:?}"
            );
            let _ = crate::adapters::common::remove_link_only(&link);
        }

        let _ = fs::remove_dir_all(&root);
        let _ = fs::remove_dir_all(&outside);
    }

    #[test]
    fn before_command_detects_dangerous_git_and_gh_ops_with_quotes_and_chains() {
        let _lock = lock_hook_env();
        let _env = clear_hook_env();
        let cfg = HookConfig::default();

        let root = temp_dir("cmd_repo");
        fs::create_dir_all(root.join(".b3")).unwrap();
        let root_str = root.to_string_lossy().into_owned();

        for blocked in [
            "git push --force origin main",
            "git push -f",
            "echo ok && git -C sub push --force",
            "git reset --hard HEAD~1",
            "git commit -m 'msg' --no-verify",
            "git commit -anm 'msg'",
            "git add -A",
            "git add .",
            "git add .b3/ship/runs/r1",
            "git add .b3/research-ship",
            "gh pr merge 42 --squash",
            "B3_MERGE_AUTHORIZED=1 gh pr merge 42",
        ] {
            let out = dispatch_event(&make_cmd_event(Some(&root_str), blocked), &cfg);
            assert!(
                matches!(out, HookOutcome::Deny { .. }),
                "expected Deny for `{blocked}`, got {out:?}"
            );
        }

        for allowed in [
            "git status",
            "git push --force-with-lease origin feat",
            "git reset --soft HEAD~1",
            "git commit -m \"allow --no-verify in text\"",
            "git commit -m -n",
            "git add src/hook/dispatch.rs",
            "git add -u",
            "echo 'git push --force'",
            "# git reset --hard",
            "cargo test --lib",
        ] {
            let out = dispatch_event(&make_cmd_event(Some(&root_str), allowed), &cfg);
            assert_eq!(out, HookOutcome::Allow, "expected Allow for `{allowed}`");
        }

        // `gh pr merge` allowed only when process env B3_MERGE_AUTHORIZED=1
        {
            let _auth = EnvGuard::new(&[("B3_MERGE_AUTHORIZED", Some("1"))]);
            assert_eq!(
                dispatch_event(&make_cmd_event(Some(&root_str), "gh pr merge 42"), &cfg),
                HookOutcome::Allow
            );
        }

        // `git add -A` allowed when `.b3/` does not exist
        fs::remove_dir_all(root.join(".b3")).unwrap();
        assert_eq!(
            dispatch_event(&make_cmd_event(Some(&root_str), "git add -A"), &cfg),
            HookOutcome::Allow
        );

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn before_commit_reuses_precommit_and_respects_skip_tree_cache() {
        let _lock = lock_hook_env();
        let _env = clear_hook_env();

        let repo = temp_dir("precommit_git");
        let no_env: [(&str, &str); 0] = [];
        assert_eq!(
            run_git(&repo, &["init"], &no_env, None).unwrap().exit_code,
            0
        );
        assert_eq!(
            run_git(
                &repo,
                &["config", "user.email", "test@example.com"],
                &no_env,
                None
            )
            .unwrap()
            .exit_code,
            0
        );
        assert_eq!(
            run_git(&repo, &["config", "user.name", "Test"], &no_env, None)
                .unwrap()
                .exit_code,
            0
        );

        fs::write(repo.join("hello.txt"), "hi\n").unwrap();
        assert_eq!(
            run_git(&repo, &["add", "hello.txt"], &no_env, None)
                .unwrap()
                .exit_code,
            0
        );

        let repo_str = repo.to_string_lossy().into_owned();
        let (_resp, out) = run_hook("git", Some("pre-commit"), Some(&repo_str), None, "").unwrap();
        assert_eq!(out, HookOutcome::Allow);

        // Secret staged -> blocked by precommit::run
        fs::write(repo.join(".env"), "SECRET=1\n").unwrap();
        assert_eq!(
            run_git(&repo, &["add", "-f", ".env"], &no_env, None)
                .unwrap()
                .exit_code,
            0
        );
        let (resp_sec, out_sec) =
            run_hook("git", Some("pre-commit"), Some(&repo_str), None, "").unwrap();
        assert!(matches!(out_sec, HookOutcome::Deny { .. }));
        assert_eq!(resp_sec.exit_code, 1);

        // Exact matching staged tree skips redundant re-check when B3_HOOK_SKIP_PRECOMMIT=1
        let wt = run_git(&repo, &["write-tree"], &no_env, None).unwrap();
        let tree_sha = String::from_utf8_lossy(&wt.stdout).trim().to_string();
        {
            let _skip = EnvGuard::new(&[
                ("B3_HOOK_SKIP_PRECOMMIT", Some("1")),
                ("B3_PRECOMMIT_VERIFIED_TREE", Some(&tree_sha)),
            ]);
            let (_, out_skip) =
                run_hook("git", Some("pre-commit"), Some(&repo_str), None, "").unwrap();
            assert_eq!(out_skip, HookOutcome::Allow);
        }

        // Mismatched tree digest does NOT skip
        {
            let _skip_bad = EnvGuard::new(&[
                ("B3_HOOK_SKIP_PRECOMMIT", Some("1")),
                (
                    "B3_PRECOMMIT_VERIFIED_TREE",
                    Some("0000000000000000000000000000000000000000"),
                ),
            ]);
            let (_, out_bad) =
                run_hook("git", Some("pre-commit"), Some(&repo_str), None, "").unwrap();
            assert!(matches!(out_bad, HookOutcome::Deny { .. }));
        }

        let _ = fs::remove_dir_all(&repo);
    }

    #[test]
    fn after_file_write_advisory_and_run_hook_mode_overrides() {
        let _lock = lock_hook_env();
        let _env = clear_hook_env();

        let dir = temp_dir("after_write");
        let dir_str = dir.to_string_lossy().into_owned();

        // Without B3_VERIFY_RECEIPT -> Allow
        let after_payload = format!(
            r#"{{"hook_event_name":"afterFileEdit","file_path":"src/lib.rs","workspace_roots":["{}"]}}"#,
            dir_str.replace('\\', "/")
        );
        let (_, out_clean) =
            run_hook("cursor", None, Some(&dir_str), None, &after_payload).unwrap();
        assert_eq!(out_clean, HookOutcome::Allow);

        // With B3_VERIFY_RECEIPT set -> Advisory (never blocks)
        {
            let _rec = EnvGuard::new(&[("B3_VERIFY_RECEIPT", Some(".b3/verify.receipt"))]);
            let (resp_adv, out_adv) =
                run_hook("cursor", None, Some(&dir_str), None, &after_payload).unwrap();
            assert!(matches!(out_adv, HookOutcome::Advisory { .. }));
            assert_eq!(resp_adv.exit_code, 0);
            assert!(!resp_adv.stderr.is_empty());
        }

        // Mode override: audit downgrades Deny to Advisory; off allows
        let force_payload =
            r#"{"hook_event_name":"beforeShellExecution","command":"git push --force"}"#;
        let (resp_audit, out_audit) =
            run_hook("cursor", None, Some(&dir_str), Some("audit"), force_payload).unwrap();
        assert_eq!(resp_audit.exit_code, 0);
        match out_audit {
            HookOutcome::Advisory { message } => assert!(message.starts_with("[audit] ")),
            other => panic!("expected Advisory, got {other:?}"),
        }

        let (resp_off, out_off) =
            run_hook("cursor", None, Some(&dir_str), Some("off"), force_payload).unwrap();
        assert_eq!(resp_off.exit_code, 0);
        assert_eq!(out_off, HookOutcome::Allow);

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn completion_loop_prevention_and_non_governed_push() {
        let _lock = lock_hook_env();
        let _env = clear_hook_env();

        let dir = temp_dir("push_and_stop");
        let dir_str = dir.to_string_lossy().into_owned();
        let cfg = HookConfig::default();

        // Ordinary non-governed repo -> BeforePush Allow
        let (_, push_out) = run_hook("git", Some("pre-push"), Some(&dir_str), None, "").unwrap();
        assert_eq!(push_out, HookOutcome::Allow);

        // Governed repo without evidence -> BeforePush Deny
        fs::create_dir_all(dir.join(".b3")).unwrap();
        fs::write(dir.join(".b3").join("research-policy.json"), "{}").unwrap();
        let (_, push_gov) = run_hook("git", Some("pre-push"), Some(&dir_str), None, "").unwrap();
        assert!(matches!(push_gov, HookOutcome::Deny { .. }));

        // Stop with continuation_active=true returns Allow even if verify receipt missing
        let stop_ev = NormalizedEvent {
            host: HostId::Claude,
            event: EventKind::TaskCompletion,
            raw_event_name: "Stop".to_string(),
            project_root: Some(dir_str.clone()),
            cwd: Some(dir_str),
            session_id: None,
            worker_id: None,
            run_id: None,
            operation_id: None,
            tool_name: None,
            affected_paths: Vec::new(),
            command: None,
            continuation_active: true,
            state_fingerprint: None,
        };
        {
            let _rec = EnvGuard::new(&[("B3_VERIFY_RECEIPT", Some(".b3/missing.receipt"))]);
            assert_eq!(dispatch_event(&stop_ev, &cfg), HookOutcome::Allow);
            let mut stop_inactive = stop_ev;
            stop_inactive.continuation_active = false;
            assert!(matches!(
                dispatch_event(&stop_inactive, &cfg),
                HookOutcome::Advisory { .. }
            ));
        }

        let _ = fs::remove_dir_all(&dir);
    }
}
