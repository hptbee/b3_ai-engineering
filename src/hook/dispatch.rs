use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

use crate::adapters::common::{normalize_abs_path_str, resolve_user_home_dir};
use crate::error::{fail, B3Error};
use crate::fs::{
    find_reparse_in_path_hierarchy, has_control_chars, is_reparse_or_symlink,
    is_unc_or_network_path, normalize_path_value, resolve_safe_repo_write_path,
    resolve_unresolved_path, split_path_csv_checked, test_checkpoint_path, test_path_match,
    test_secret_path,
};
use crate::guard::{merge_policy, precommit, verify::test_verify_receipt};
use crate::hook::config::{
    default_global_preferences_path, default_project_preferences_path, resolve_hook_config,
    HookConfig, HookConfigOverride, HookMode,
};
use crate::hook::event::{
    normalize_event, EventKind, HostId, NormalizedEvent, MAX_HOOK_PAYLOAD_BYTES,
};
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
    if has_control_chars(raw) || is_unc_or_network_path(raw, Path::new(raw)) {
        return None;
    }
    Some(resolve_lexical_root(raw))
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

fn guess_event_kind(event_hint: Option<&str>) -> EventKind {
    match event_hint.unwrap_or("").trim() {
        "Stop" | "stop" | "SubagentStop" | "subagentStop" => EventKind::TaskCompletion,
        "PostToolUse"
        | "postToolUse"
        | "PostInvocation"
        | "afterFileEdit"
        | "afterShellExecution" => EventKind::AfterFileWrite,
        "SessionStart" | "sessionStart" => EventKind::SessionStart,
        "SessionEnd" | "sessionEnd" => EventKind::SessionEnd,
        "pre-commit" => EventKind::BeforeCommit,
        "pre-push" => EventKind::BeforePush,
        "pre-merge-commit" => EventKind::BeforeMerge,
        _ => EventKind::BeforeCommand,
    }
}

fn read_hook_stdin_bounded() -> Result<String, B3Error> {
    let limit = MAX_HOOK_PAYLOAD_BYTES as u64 + 1;
    let mut buf = Vec::new();
    std::io::stdin()
        .take(limit)
        .read_to_end(&mut buf)
        .map_err(|e| fail(format!("HOOK_IO_FAIL: cannot read stdin: {e}"), 1))?;
    if buf.len() > MAX_HOOK_PAYLOAD_BYTES {
        return Err(fail(
            format!("HOOK_PAYLOAD_TOO_LARGE: stdin exceeds {MAX_HOOK_PAYLOAD_BYTES} bytes"),
            1,
        ));
    }
    String::from_utf8(buf)
        .map_err(|e| fail(format!("HOOK_INVALID_UTF8: invalid UTF-8 on stdin: {e}"), 1))
}

fn resolve_project_pref_path(raw_dir: &str, is_explicit_repo: bool) -> PathBuf {
    let dir = resolve_lexical_root(raw_dir);
    if is_explicit_repo {
        return default_project_preferences_path(&dir);
    }
    let home_cmp = norm_cmp_path(&resolve_user_home_dir(None));
    let tmp_cmp = norm_cmp_path(&std::env::temp_dir());
    let mut cur = Some(dir.as_path());
    while let Some(c) = cur {
        let c_cmp = norm_cmp_path(c);
        if c.parent().is_none() || c_cmp == home_cmp || c_cmp == tmp_cmp || is_reparse_or_symlink(c)
        {
            break;
        }
        let dot_b3 = c.join(".b3");
        let toml_pref = dot_b3.join("config.toml");
        if !is_reparse_or_symlink(&dot_b3) {
            if toml_pref.is_file() && !is_reparse_or_symlink(&toml_pref) {
                return toml_pref;
            }
            let md_pref = dot_b3.join("models.md");
            if md_pref.is_file() && !is_reparse_or_symlink(&md_pref) {
                return md_pref;
            }
        }
        if c.join(".git").exists() {
            return toml_pref;
        }
        cur = c.parent();
    }
    default_project_preferences_path(&dir)
}

fn resolve_cfg_for_root(
    root: Option<(&str, bool)>,
    mode_ov: Option<HookMode>,
) -> (HookConfig, Vec<String>) {
    let project_pref = root.map(|(r, is_explicit)| resolve_project_pref_path(r, is_explicit));
    let global_pref = default_global_preferences_path(None);
    let cli_ov = mode_ov.map(|m| HookConfigOverride {
        enabled: None,
        mode: Some(m),
    });
    resolve_hook_config(project_pref.as_deref(), Some(&global_pref), cli_ov)
}

fn mode_outcome_for_error(mode: HookMode, message: &str) -> HookOutcome {
    match mode {
        HookMode::Off => HookOutcome::Allow,
        HookMode::Audit => HookOutcome::Advisory {
            message: format!("[audit] {message}"),
        },
        HookMode::Enforce => HookOutcome::Deny {
            message: message.to_string(),
        },
    }
}

/// CLI entrypoint for `b3 hook run` with early mode resolution (F05),
/// bounded stdin reading, and host-protocol formatting.
pub(crate) fn run_hook_cli(
    host_raw: &str,
    event_hint: Option<&str>,
    repo_root_raw: Option<&str>,
    mode_override: Option<&str>,
    payload_opt: Option<&str>,
    git_args: &[String],
) -> Result<HostResponse, B3Error> {
    let (resp, _) = run_hook_internal(
        host_raw,
        event_hint,
        repo_root_raw,
        mode_override,
        payload_opt,
        git_args,
    )?;
    Ok(resp)
}

/// Evaluates an in-memory hook payload and returns both `HostResponse` and `HookOutcome`.
#[cfg(test)]
fn run_hook(
    host_raw: &str,
    event_hint: Option<&str>,
    repo_root_raw: Option<&str>,
    mode_override: Option<&str>,
    payload_raw: &str,
) -> Result<(HostResponse, HookOutcome), B3Error> {
    run_hook_internal(
        host_raw,
        event_hint,
        repo_root_raw,
        mode_override,
        Some(payload_raw),
        &[],
    )
}

fn run_hook_internal(
    host_raw: &str,
    event_hint: Option<&str>,
    repo_root_raw: Option<&str>,
    mode_override: Option<&str>,
    payload_opt: Option<&str>,
    git_args: &[String],
) -> Result<(HostResponse, HookOutcome), B3Error> {
    let host = HostId::parse(host_raw)?;
    let mode_ov = match mode_override.map(str::trim).filter(|s| !s.is_empty()) {
        Some(raw) => Some(HookMode::parse(raw)?),
        None => None,
    };
    let explicit_repo = repo_root_raw.map(str::trim).filter(|s| !s.is_empty());
    if let Some(r) = explicit_repo {
        if has_control_chars(r) {
            return Err(fail(
                "HOOK_INVALID_FIELD: control characters rejected in repo_root",
                1,
            ));
        }
    }

    let raw_ev_hint = event_hint.unwrap_or("").trim();
    let kind_hint = guess_event_kind(event_hint);

    if is_hook_recursion_active() || mode_ov == Some(HookMode::Off) {
        let resp = format_response(host, raw_ev_hint, kind_hint, &HookOutcome::Allow);
        return Ok((resp, HookOutcome::Allow));
    }
    if mode_ov.is_none() && env_nonempty("B3_HOOK_MODE").is_some_and(|m| m == "off") {
        let resp = format_response(host, raw_ev_hint, kind_hint, &HookOutcome::Allow);
        return Ok((resp, HookOutcome::Allow));
    }

    let cwd_fallback = std::env::current_dir()
        .ok()
        .map(|p| p.to_string_lossy().into_owned());
    let early_root = explicit_repo.or(cwd_fallback.as_deref());
    let (early_cfg, early_warnings) =
        resolve_cfg_for_root(early_root.map(|r| (r, explicit_repo.is_some())), mode_ov);

    if explicit_repo.is_some() && early_cfg.effective_mode() == HookMode::Off {
        let resp = format_response(host, raw_ev_hint, kind_hint, &HookOutcome::Allow);
        return Ok((resp, HookOutcome::Allow));
    }

    let owned_stdin;
    let payload_raw = match payload_opt {
        Some(p) => p,
        None => match read_hook_stdin_bounded() {
            Ok(s) => {
                owned_stdin = s;
                &owned_stdin
            }
            Err(e) => {
                let outcome = mode_outcome_for_error(early_cfg.effective_mode(), &e.message);
                let mut resp = format_response(host, raw_ev_hint, kind_hint, &outcome);
                append_warnings_to_stderr(&mut resp, &early_warnings, early_cfg.effective_mode());
                return Ok((resp, outcome));
            }
        },
    };

    let mut event = match normalize_event(host, event_hint, payload_raw, early_root) {
        Ok(ev) => ev,
        Err(e) => {
            let outcome = mode_outcome_for_error(early_cfg.effective_mode(), &e.message);
            let mut resp = format_response(host, raw_ev_hint, kind_hint, &outcome);
            append_warnings_to_stderr(&mut resp, &early_warnings, early_cfg.effective_mode());
            return Ok((resp, outcome));
        }
    };

    if let Some(r) = explicit_repo {
        event.project_root = Some(r.to_string());
    }
    event.git_args = git_args.to_vec();

    let ev_root = event
        .project_root
        .as_deref()
        .or(event.cwd.as_deref())
        .or(cwd_fallback.as_deref());
    let same_root = explicit_repo.is_some()
        || match (ev_root, early_root) {
            (Some(a), Some(b)) => {
                norm_cmp_path(&resolve_lexical_root(a)) == norm_cmp_path(&resolve_lexical_root(b))
            }
            (None, None) => true,
            _ => false,
        };
    let (cfg, warnings) = if same_root {
        (early_cfg, early_warnings)
    } else {
        resolve_cfg_for_root(ev_root.map(|r| (r, false)), mode_ov)
    };

    if cfg.effective_mode() == HookMode::Off {
        let resp = format_response(
            host,
            &event.raw_event_name,
            event.event,
            &HookOutcome::Allow,
        );
        return Ok((resp, HookOutcome::Allow));
    }

    let _active_guard = HookActiveEnvGuard::activate();
    let outcome = dispatch_event_inner(&event, &cfg);
    let mut resp = format_response(host, &event.raw_event_name, event.event, &outcome);
    append_warnings_to_stderr(&mut resp, &warnings, cfg.effective_mode());
    Ok((resp, outcome))
}

fn append_warnings_to_stderr(resp: &mut HostResponse, warnings: &[String], mode: HookMode) {
    if mode == HookMode::Off || warnings.is_empty() {
        return;
    }
    for w in warnings {
        if !resp.stderr.is_empty() && !resp.stderr.ends_with('\n') {
            resp.stderr.push('\n');
        }
        resp.stderr.push_str(w);
    }
}

/// Evaluates a normalized hook event against `cfg` without host-specific serialization.
#[cfg(test)]
fn dispatch_event(event: &NormalizedEvent, cfg: &HookConfig) -> HookOutcome {
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

fn norm_cmp_path(p: &Path) -> String {
    crate::hook::norm_cmp_path(p)
}

/// Pure-FS check (0 Git subprocesses) that recognizes a sibling linked worktree
/// whose `.git` file points to `<main_root>/.git/worktrees/<name>` and whose
/// corresponding `<main_root>/.git/worktrees/<name>/gitdir` points back to `<wt>/.git`.
fn valid_worktrees_dir(main_root: &Path) -> Option<PathBuf> {
    if is_reparse_or_symlink(main_root) {
        return None;
    }
    let dot_git_main = main_root.join(".git");
    let wt_dir = dot_git_main.join("worktrees");
    (!is_reparse_or_symlink(&dot_git_main) && wt_dir.is_dir() && !is_reparse_or_symlink(&wt_dir))
        .then_some(wt_dir)
}

fn find_linked_worktree_root(
    main_root: &Path,
    main_reparse_anc: Option<&Path>,
    worktrees_dir: Option<&Path>,
    raw_path: &str,
) -> Option<PathBuf> {
    let wt_dir = worktrees_dir?;
    let wt_dir_norm = norm_cmp_path(wt_dir);

    let abs_target = resolve_unresolved_path(main_root, raw_path);
    let mut cur = abs_target.parent();
    while let Some(dir) = cur {
        let dot_git = dir.join(".git");
        if let Ok(meta) = fs::symlink_metadata(&dot_git) {
            if meta.is_file() && !is_reparse_or_symlink(&dot_git) && meta.len() <= 4096 {
                if let Ok(content) = fs::read_to_string(&dot_git) {
                    if let Some(rest) = content.trim().strip_prefix("gitdir:") {
                        let gd = resolve_unresolved_path(dir, rest.trim());
                        let valid_admin = gd.is_dir()
                            && !is_reparse_or_symlink(&gd)
                            && gd.parent().is_some_and(|p| norm_cmp_path(p) == wt_dir_norm);
                        if valid_admin {
                            let back = gd.join("gitdir");
                            let back_ok = fs::symlink_metadata(&back).is_ok_and(|bm| {
                                bm.is_file() && !is_reparse_or_symlink(&back) && bm.len() <= 4096
                            }) && fs::read_to_string(&back).is_ok_and(|bp| {
                                norm_cmp_path(&resolve_unresolved_path(&gd, bp.trim()))
                                    == norm_cmp_path(&dot_git)
                            });
                            let reparse_ok = !is_reparse_or_symlink(dir)
                                && match (main_reparse_anc, find_reparse_in_path_hierarchy(dir)) {
                                    (_, None) => true,
                                    (Some(ma), Some(da)) => norm_cmp_path(ma) == norm_cmp_path(&da),
                                    (None, Some(_)) => false,
                                };
                            if back_ok && reparse_ok {
                                return Some(dir.to_path_buf());
                            }
                        }
                    }
                }
            }
            // Do not walk past an unrelated git boundary.
            return None;
        }
        cur = dir.parent();
    }
    None
}

fn check_resolved_target(
    full: &Path,
    rel: &str,
    worker_allowed: Option<&[String]>,
) -> Option<String> {
    if is_reparse_or_symlink(full) {
        return Some(format!(
            "HOOK_BLOCKED: target is a symlink or reparse point: {rel}"
        ));
    }
    if is_git_internal_path(rel) {
        return Some(format!("HOOK_BLOCKED: protected path '.git': {rel}"));
    }
    if is_ship_evidence_path(rel) {
        return Some(format!("HOOK_BLOCKED: protected ship evidence path: {rel}"));
    }
    if rel.eq_ignore_ascii_case(".b3/policy.toml")
        || rel.eq_ignore_ascii_case(".b3/research-policy.json")
    {
        return Some(format!(
            "HOOK_BLOCKED: protected governance policy path: {rel}"
        ));
    }
    if test_secret_path(rel) {
        return Some(format!("HOOK_BLOCKED: protected secret path: {rel}"));
    }
    if let Some(allowed) = worker_allowed {
        if !test_path_match(rel, allowed) {
            return Some(format!(
                "HOOK_BLOCKED: write outside B3_WORKER_ALLOWED_PATHS: {rel}"
            ));
        }
    }
    None
}

fn eval_before_file_write(event: &NormalizedEvent) -> HookOutcome {
    let Some(root) = resolve_event_project_root(event) else {
        return HookOutcome::Deny {
            message: "HOOK_BLOCKED: BeforeFileWrite requires resolved project_root".to_string(),
        };
    };
    if event.affected_paths.is_empty() {
        return HookOutcome::Deny {
            message: "HOOK_BLOCKED: BeforeFileWrite payload did not specify a target path"
                .to_string(),
        };
    }
    if is_reparse_or_symlink(&root) {
        return HookOutcome::Deny {
            message: format!(
                "HOOK_BLOCKED: project_root is a symlink or reparse point: {}",
                root.display()
            ),
        };
    }

    let main_reparse_anc = find_reparse_in_path_hierarchy(&root);
    let worker_allowed = match parse_optional_env_paths("B3_WORKER_ALLOWED_PATHS") {
        Ok(v) => v,
        Err(e) => return HookOutcome::Deny { message: e.message },
    };

    let worktrees_dir = valid_worktrees_dir(&root);

    for raw_path in &event.affected_paths {
        if let Some((full, rel)) = resolve_safe_repo_write_path(&root, raw_path) {
            if let Some(msg) = check_resolved_target(&full, &rel, worker_allowed.as_deref()) {
                return HookOutcome::Deny { message: msg };
            }
            continue;
        }

        if let Some(wt_root) = find_linked_worktree_root(
            &root,
            main_reparse_anc.as_deref(),
            worktrees_dir.as_deref(),
            raw_path,
        ) {
            if let Some((full, rel)) = resolve_safe_repo_write_path(&wt_root, raw_path) {
                if let Some(msg) = check_resolved_target(&full, &rel, worker_allowed.as_deref()) {
                    return HookOutcome::Deny { message: msg };
                }
                continue;
            }
        }

        let norm_raw = normalize_path_value(raw_path);
        let msg = if is_git_internal_path(&norm_raw) {
            format!("HOOK_BLOCKED: protected path '.git' cannot be modified: {raw_path}")
        } else {
            format!(
                "HOOK_BLOCKED: unsafe write path (outside project_root, traversal, or symlink/reparse): {raw_path}"
            )
        };
        return HookOutcome::Deny { message: msg };
    }

    HookOutcome::Allow
}

// Lightweight lexical Git command tripwire (Tier 0, 0 Git subprocesses, not a security sandbox).
fn tokenize_shell_segments(cmd: &str) -> Vec<Vec<String>> {
    let mut chars = cmd.chars().peekable();
    let mut segments: Vec<Vec<String>> = Vec::new();
    let mut cur_seg: Vec<String> = Vec::new();
    let mut cur_tok = String::new();
    let mut in_tok = false;
    let mut quote: Option<char> = None;
    let mut prev_redir = false;

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

    while let Some(ch) = chars.next() {
        match quote {
            Some('\'') => {
                if ch == '\'' {
                    quote = None;
                } else {
                    cur_tok.push(ch);
                }
                prev_redir = false;
            }
            Some('"') => {
                if ch == '\\' && matches!(chars.peek(), Some('"' | '\\' | '$' | '`' | '\n')) {
                    if let Some(next_ch) = chars.next() {
                        if next_ch != '\n' {
                            cur_tok.push(next_ch);
                        }
                    }
                } else if ch == '"' {
                    quote = None;
                } else {
                    cur_tok.push(ch);
                }
                prev_redir = false;
            }
            _ => match ch {
                ' ' | '\t' | '\r' => {
                    flush_tok(&mut cur_tok, &mut in_tok, &mut cur_seg);
                    prev_redir = false;
                }
                '\n' | ';' | '(' | ')' => {
                    flush_seg(&mut cur_tok, &mut in_tok, &mut cur_seg, &mut segments);
                    prev_redir = false;
                }
                '{' | '}' if !in_tok => {
                    flush_seg(&mut cur_tok, &mut in_tok, &mut cur_seg, &mut segments);
                    prev_redir = false;
                }
                '|' => {
                    flush_seg(&mut cur_tok, &mut in_tok, &mut cur_seg, &mut segments);
                    let _ = chars.next_if_eq(&'|');
                    prev_redir = false;
                }
                '&' if prev_redir => {
                    cur_tok.push('&');
                    in_tok = true;
                    prev_redir = false;
                }
                '&' => {
                    flush_seg(&mut cur_tok, &mut in_tok, &mut cur_seg, &mut segments);
                    let _ = chars.next_if_eq(&'&');
                    prev_redir = false;
                }
                '#' if !in_tok => {
                    for c in chars.by_ref() {
                        if c == '\n' {
                            break;
                        }
                    }
                    prev_redir = false;
                }
                '\'' | '"' => {
                    quote = Some(ch);
                    in_tok = true;
                    prev_redir = false;
                }
                '\\' => {
                    if let Some(next_ch) = chars.next() {
                        if next_ch != '\n' {
                            cur_tok.push(next_ch);
                            in_tok = true;
                        }
                    }
                    prev_redir = false;
                }
                _ => {
                    cur_tok.push(ch);
                    in_tok = true;
                    prev_redir = matches!(ch, '>' | '<');
                }
            },
        }
    }
    flush_seg(&mut cur_tok, &mut in_tok, &mut cur_seg, &mut segments);
    segments
}

fn is_env_assignment(tok: &str) -> bool {
    tok.split_once('=').is_some_and(|(name, _)| {
        let mut ch = name.chars();
        ch.next()
            .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
            && ch.all(|c| c.is_ascii_alphanumeric() || c == '_')
    })
}

fn command_basename(raw: &str) -> String {
    let leaf = raw
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or(raw)
        .to_ascii_lowercase();
    leaf.strip_suffix(".exe")
        .or_else(|| leaf.strip_suffix(".cmd"))
        .or_else(|| leaf.strip_suffix(".bat"))
        .unwrap_or(&leaf)
        .to_string()
}

fn strip_command_wrappers(mut seg: &[String]) -> &[String] {
    loop {
        while seg.first().is_some_and(|s| is_env_assignment(s)) {
            seg = &seg[1..];
        }
        let Some(first) = seg.first() else {
            return seg;
        };
        match command_basename(first).as_str() {
            "command" | "exec" | "nohup" | "time" => {
                seg = &seg[1..];
                while let Some(arg) = seg.first() {
                    if arg == "--" {
                        seg = &seg[1..];
                        break;
                    }
                    if arg.starts_with('-') {
                        seg = &seg[1..];
                    } else {
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
                    if matches!(arg.as_str(), "-u" | "--unset" | "-C" | "--chdir") {
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

fn parse_git_subcommand(args: &[String]) -> Option<(&str, &[String])> {
    let mut i = 0usize;
    while i < args.len() {
        let a = args[i].as_str();
        if !a.starts_with('-') {
            return Some((a, &args[i + 1..]));
        }
        if a == "--" {
            return None;
        }
        i += if matches!(
            a,
            "-C" | "-c"
                | "--git-dir"
                | "--work-tree"
                | "--namespace"
                | "--super-prefix"
                | "--config-env"
                | "--exec-path"
        ) {
            2
        } else {
            1
        };
    }
    None
}

fn short_cluster_has(arg: &str, needle: char, value_flags: &[char]) -> bool {
    arg.starts_with('-')
        && !arg.starts_with("--")
        && arg.len() >= 2
        && arg[1..]
            .chars()
            .take_while(|c| !value_flags.contains(c))
            .any(|c| c == needle)
}

fn eval_git_command(subcmd: &str, args: &[String], project_root: Option<&Path>) -> Option<String> {
    match subcmd {
        "push" => {
            for arg in args {
                if arg == "--" {
                    break;
                }
                if arg == "--force" || short_cluster_has(arg, 'f', &['o', 'C']) {
                    return Some("HOOK_BLOCKED: 'git push --force' / '-f' is blocked (use --force-with-lease if intentional)".to_string());
                }
            }
        }
        "reset" => {
            for arg in args {
                if arg == "--" {
                    break;
                }
                if arg == "--hard" {
                    return Some("HOOK_BLOCKED: 'git reset --hard' is blocked".to_string());
                }
            }
        }
        "commit" => {
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
                if arg == "--no-verify" || short_cluster_has(arg, 'n', &value_short) {
                    return Some(
                        "HOOK_BLOCKED: 'git commit --no-verify' / '-n' is blocked".to_string(),
                    );
                }
                let ends_with_val = arg.starts_with('-')
                    && !arg.starts_with("--")
                    && arg[1..]
                        .chars()
                        .last()
                        .is_some_and(|c| value_short.contains(&c));
                if value_long.contains(&arg.as_str()) || ends_with_val {
                    skip_next = true;
                }
            }
        }
        "add" => {
            let mut has_all = false;
            let mut after_dd = false;
            let mut skip_next = false;
            let mut has_dot = false;
            for arg in args {
                if skip_next {
                    skip_next = false;
                    continue;
                }
                if !after_dd && arg == "--" {
                    after_dd = true;
                    continue;
                }
                if !after_dd && arg.starts_with('-') {
                    if arg == "--all" || short_cluster_has(arg, 'A', &[]) {
                        has_all = true;
                    } else if matches!(arg.as_str(), "--chmod" | "--pathspec-from-file") {
                        skip_next = true;
                    }
                    continue;
                }
                let trimmed = arg.trim_end_matches(['/', '\\']);
                let norm = normalize_path_value(if trimmed.is_empty() { arg } else { trimmed })
                    .to_ascii_lowercase();
                if norm == "." || norm == "./" {
                    has_dot = true;
                }
                if norm == ".b3"
                    || norm == ".b3/ship"
                    || norm.starts_with(".b3/ship/")
                    || norm == ".b3/research-ship"
                    || norm.starts_with(".b3/research-ship/")
                    || test_checkpoint_path(&norm)
                {
                    return Some(format!(
                        "HOOK_BLOCKED: staging B3 checkpoint path is blocked: {arg}"
                    ));
                }
            }
            if (has_all || has_dot) && project_root.is_some_and(|r| r.join(".b3").is_dir()) {
                return Some("HOOK_BLOCKED: 'git add -A' / 'git add .' is blocked when .b3/ exists (stage explicit paths instead)".to_string());
            }
        }
        _ => {}
    }
    None
}

fn is_protected_hook_env_name(name: &str) -> bool {
    matches!(name, "B3_HOOK_ACTIVE" | "B3_HOOK_MODE")
}

fn sets_protected_hook_env(mut seg: &[String]) -> bool {
    loop {
        while let Some(first) = seg.first() {
            if let Some((k, _)) = first.split_once('=') {
                if is_protected_hook_env_name(k) {
                    return true;
                }
                if is_env_assignment(first) {
                    seg = &seg[1..];
                    continue;
                }
            }
            break;
        }
        let Some(first) = seg.first() else {
            return false;
        };
        match command_basename(first).as_str() {
            "command" | "exec" | "nohup" | "time" => {
                seg = &seg[1..];
                while let Some(a) = seg.first() {
                    if a == "--" {
                        seg = &seg[1..];
                        break;
                    }
                    if a.starts_with('-') {
                        seg = &seg[1..];
                    } else {
                        break;
                    }
                }
            }
            "env" => {
                seg = &seg[1..];
                while let Some(a) = seg.first() {
                    if a == "--" {
                        seg = &seg[1..];
                        break;
                    }
                    if let Some((k, _)) = a.split_once('=') {
                        if is_protected_hook_env_name(k) {
                            return true;
                        }
                        if is_env_assignment(a) {
                            seg = &seg[1..];
                            continue;
                        }
                    }
                    if matches!(a.as_str(), "-u" | "--unset" | "-C" | "--chdir") {
                        seg = if seg.len() >= 2 { &seg[2..] } else { &[] };
                    } else if a.starts_with('-') {
                        seg = &seg[1..];
                    } else {
                        break;
                    }
                }
            }
            "export" => {
                return seg[1..].iter().any(|a| {
                    is_protected_hook_env_name(a)
                        || a.split_once('=')
                            .is_some_and(|(k, _)| is_protected_hook_env_name(k))
                });
            }
            _ => return false,
        }
    }
}

fn eval_before_command(event: &NormalizedEvent) -> HookOutcome {
    let Some(cmd_raw) = event.command.as_deref().filter(|s| !s.trim().is_empty()) else {
        return HookOutcome::Allow;
    };
    let project_root = resolve_event_project_root(event);
    for seg in &tokenize_shell_segments(cmd_raw) {
        if sets_protected_hook_env(seg) {
            return HookOutcome::Deny {
                message: "HOOK_BLOCKED: setting B3_HOOK_ACTIVE or B3_HOOK_MODE in shell commands is blocked"
                    .to_string(),
            };
        }
        let Some((prog_raw, args)) = strip_command_wrappers(seg).split_first() else {
            continue;
        };
        if command_basename(prog_raw) == "git" {
            if let Some((subcmd, sub_args)) = parse_git_subcommand(args) {
                if let Some(msg) = eval_git_command(subcmd, sub_args, project_root.as_deref()) {
                    return HookOutcome::Deny { message: msg };
                }
            }
        }
    }
    HookOutcome::Allow
}

fn eval_before_commit(event: &NormalizedEvent) -> HookOutcome {
    let Some(root) = resolve_event_project_root(event) else {
        return HookOutcome::Deny {
            message: "HOOK_BLOCKED: BeforeCommit requires resolved project_root".to_string(),
        };
    };
    let root_str = root.to_string_lossy().into_owned();
    let receipt = env_nonempty("B3_VERIFY_RECEIPT").unwrap_or_default();
    let allowed = env_nonempty("B3_ALLOWED_PATHS");

    match precommit::run_for_hook(&root_str, allowed.as_deref(), &receipt) {
        Ok(_) => HookOutcome::Allow,
        Err(e) => HookOutcome::Deny { message: e.message },
    }
}

fn eval_before_push_or_merge(event: &NormalizedEvent) -> HookOutcome {
    let Some(root) = resolve_event_project_root(event) else {
        return HookOutcome::Deny {
            message: format!(
                "HOOK_BLOCKED: {} requires resolved project_root",
                event.event.as_str()
            ),
        };
    };
    let root_str = root.to_string_lossy().into_owned();
    let ledger_path = env_nonempty("B3_LEDGER_PATH").unwrap_or_default();
    let receipt_path = env_nonempty("B3_VERIFY_RECEIPT").unwrap_or_default();
    let is_push = event.event == EventKind::BeforePush;

    match merge_policy::check_git_hook_operation(
        &root_str,
        is_push,
        &event.git_args,
        &event.git_stdin,
        &ledger_path,
        &receipt_path,
    ) {
        Ok(None) => HookOutcome::Allow,
        Ok(Some(message)) => HookOutcome::Advisory { message },
        Err(e) => HookOutcome::Deny { message: e.message },
    }
}

fn check_receipt_freshness_advisory(root: &Path, edited_paths: Option<&[String]>) -> HookOutcome {
    let Some(receipt_path) = env_nonempty("B3_VERIFY_RECEIPT") else {
        return HookOutcome::Allow;
    };
    let vr = test_verify_receipt(root, &receipt_path, &[], "", "", "");
    if vr.code != 0 {
        return HookOutcome::Advisory {
            message: format!(
                "HOOK_ADVISORY: verification receipt '{}' is not fresh ({}); re-verify before commit",
                receipt_path, vr.message
            ),
        };
    }

    if let Some(paths) = edited_paths.filter(|p| !p.is_empty()) {
        let main_reparse_anc = find_reparse_in_path_hierarchy(root);
        let worktrees_dir = valid_worktrees_dir(root);
        let rel_paths: Vec<String> = paths
            .iter()
            .filter_map(|p| {
                resolve_safe_repo_write_path(root, p)
                    .map(|(_, rel)| rel)
                    .or_else(|| {
                        find_linked_worktree_root(
                            root,
                            main_reparse_anc.as_deref(),
                            worktrees_dir.as_deref(),
                            p,
                        )
                        .and_then(|wt| resolve_safe_repo_write_path(&wt, p))
                        .map(|(_, rel)| rel)
                    })
            })
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
    let Some(root) = resolve_event_project_root(event) else {
        return HookOutcome::Allow;
    };
    check_receipt_freshness_advisory(&root, Some(&event.affected_paths))
}

fn eval_completion(event: &NormalizedEvent) -> HookOutcome {
    if event.continuation_active {
        return HookOutcome::Allow;
    }
    let Some(root) = resolve_event_project_root(event) else {
        return HookOutcome::Allow;
    };
    check_receipt_freshness_advisory(&root, None)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fs::next_tmp_suffix;
    use crate::git::run_git;
    use crate::json::parse_json;

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
            ("B3_WORKER_ALLOWED_PATHS", None),
            ("B3_ALLOWED_PATHS", None),
            ("B3_VERIFY_RECEIPT", None),
            ("B3_LEDGER_PATH", None),
            ("B3_CONFIG_PERSONAL", None),
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
            event: EventKind::BeforeFileWrite,
            raw_event_name: "preToolUse".to_string(),
            project_root: root.map(str::to_string),
            cwd: root.map(str::to_string),
            affected_paths: paths.iter().map(|s| (*s).to_string()).collect(),
            command: None,
            continuation_active: false,
            git_args: Vec::new(),
            git_stdin: String::new(),
        }
    }

    fn make_cmd_event(root: Option<&str>, cmd: &str) -> NormalizedEvent {
        NormalizedEvent {
            event: EventKind::BeforeCommand,
            raw_event_name: "beforeShellExecution".to_string(),
            project_root: root.map(str::to_string),
            cwd: root.map(str::to_string),
            affected_paths: Vec::new(),
            command: Some(cmd.to_string()),
            continuation_active: false,
            git_args: Vec::new(),
            git_stdin: String::new(),
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
    fn before_file_write_enforces_containment_and_linked_worktrees() {
        let _lock = lock_hook_env();
        let _env = clear_hook_env();
        let cfg = HookConfig::default();

        // Missing root or missing target path -> Deny in enforce, Advisory in audit, Allow in off
        assert!(matches!(
            dispatch_event(&make_write_event(None, &["src/lib.rs"]), &cfg),
            HookOutcome::Deny { .. }
        ));
        let root = temp_dir("write_rules");
        let root_str = root.to_string_lossy().into_owned();
        assert!(matches!(
            dispatch_event(&make_write_event(Some(&root_str), &[]), &cfg),
            HookOutcome::Deny { .. }
        ));
        let audit_cfg = HookConfig {
            enabled: true,
            mode: HookMode::Audit,
        };
        assert!(matches!(
            dispatch_event(&make_write_event(None, &["src/lib.rs"]), &audit_cfg),
            HookOutcome::Advisory { .. }
        ));

        let outside = temp_dir("outside");
        let outside_file = outside.join("escape.txt").to_string_lossy().into_owned();
        assert_eq!(
            dispatch_event(&make_write_event(Some(&root_str), &["src/main.rs"]), &cfg),
            HookOutcome::Allow
        );
        for blocked in [
            "../outside.txt",
            "src/../../outside.txt",
            &outside_file,
            ".git/config",
            ".b3/ship/runs/run-1/evidence/verify.txt",
            ".b3/research-policy.json",
            ".env",
            "keys/id_rsa",
        ] {
            assert!(
                matches!(
                    dispatch_event(&make_write_event(Some(&root_str), &[blocked]), &cfg),
                    HookOutcome::Deny { .. }
                ),
                "expected Deny for {blocked}"
            );
        }
        assert_eq!(
            dispatch_event(&make_write_event(Some(&root_str), &[".env.example"]), &cfg),
            HookOutcome::Allow
        );

        // B3_WORKER_ALLOWED_PATHS
        {
            let _g = EnvGuard::new(&[("B3_WORKER_ALLOWED_PATHS", Some("src/hook"))]);
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

        // Sibling linked worktree validation (0 Git subprocesses, requires bidirectional gitdir link)
        let wt_meta = root.join(".git/worktrees/wt1");
        let wt_sibling = temp_dir("wt_sibling");
        let wt_spoof = temp_dir("wt_spoof");
        fs::create_dir_all(&wt_meta).unwrap();
        let wt_git = wt_sibling.join(".git");
        fs::write(
            &wt_git,
            format!("gitdir: {}\n", wt_meta.to_string_lossy().replace('\\', "/")),
        )
        .unwrap();
        fs::write(
            wt_meta.join("gitdir"),
            format!("{}\n", wt_git.to_string_lossy().replace('\\', "/")),
        )
        .unwrap();
        fs::write(
            wt_spoof.join(".git"),
            format!(
                "gitdir: {}\n",
                root.join(".git/worktrees/missing")
                    .to_string_lossy()
                    .replace('\\', "/")
            ),
        )
        .unwrap();
        let wt_ok = wt_sibling.join("src/ok.rs").to_string_lossy().into_owned();
        let wt_env = wt_sibling.join(".env").to_string_lossy().into_owned();
        let spoof_ok = wt_spoof.join("src/ok.rs").to_string_lossy().into_owned();
        assert_eq!(
            dispatch_event(&make_write_event(Some(&root_str), &[&wt_ok]), &cfg),
            HookOutcome::Allow
        );
        assert!(matches!(
            dispatch_event(&make_write_event(Some(&root_str), &[&wt_env]), &cfg),
            HookOutcome::Deny { .. }
        ));
        assert!(matches!(
            dispatch_event(&make_write_event(Some(&root_str), &[&spoof_ok]), &cfg),
            HookOutcome::Deny { .. }
        ));

        #[cfg(windows)]
        {
            fs::create_dir_all(root.join(".b3")).unwrap();
            let pol = root.join(".b3/research-policy.json");
            fs::write(&pol, "{}").unwrap();
            if let Some(short_pol) = crate::fs::to_short_path(&pol) {
                let s = short_pol.to_string_lossy().into_owned();
                assert!(matches!(
                    dispatch_event(&make_write_event(Some(&root_str), &[&s]), &cfg),
                    HookOutcome::Deny { .. }
                ));
            }

            let long_container_raw = temp_dir("runneradmin_long_segment");
            let long_container = crate::fs::expand_windows_long_path(&long_container_raw);
            let long_main = long_container.join("main_repo");
            let long_wt = long_container.join("worktree_leaf");
            let long_wt_meta = long_main.join(".git/worktrees/wt_long");
            fs::create_dir_all(&long_wt_meta).unwrap();
            fs::create_dir_all(&long_wt).unwrap();
            let long_wt_git = long_wt.join(".git");
            fs::write(
                &long_wt_git,
                format!(
                    "gitdir: {}\n",
                    long_wt_meta.to_string_lossy().replace('\\', "/")
                ),
            )
            .unwrap();
            fs::write(
                long_wt_meta.join("gitdir"),
                format!("{}\n", long_wt_git.to_string_lossy().replace('\\', "/")),
            )
            .unwrap();
            if let (Some(short_main), Some(short_wt)) = (
                crate::fs::to_short_path(&long_main),
                crate::fs::to_short_path(&long_wt),
            ) {
                let sm = short_main.to_string_lossy().into_owned();
                let short_ok = short_wt.join("src/ok.rs").to_string_lossy().into_owned();
                let short_env = short_wt.join(".env").to_string_lossy().into_owned();
                assert_eq!(
                    dispatch_event(&make_write_event(Some(&sm), &[&short_ok]), &cfg),
                    HookOutcome::Allow
                );
                assert!(matches!(
                    dispatch_event(&make_write_event(Some(&sm), &[&short_env]), &cfg),
                    HookOutcome::Deny { .. }
                ));
            }
            let _ = fs::remove_dir_all(&long_container);
        }

        assert_eq!(
            crate::hook::collapse_macos_private_prefix("/private/var/folders/x"),
            "/var/folders/x"
        );
        assert_eq!(
            crate::hook::collapse_macos_private_prefix("/private/var"),
            "/var"
        );
        assert_eq!(
            crate::hook::collapse_macos_private_prefix("/private/tmp/x"),
            "/tmp/x"
        );
        assert_eq!(
            crate::hook::collapse_macos_private_prefix("/private/tmp"),
            "/tmp"
        );
        assert_eq!(
            crate::hook::collapse_macos_private_prefix("/private/etc"),
            "/private/etc"
        );
        assert_eq!(
            crate::hook::collapse_macos_private_prefix("/private/variable"),
            "/private/variable"
        );

        let _ = fs::remove_dir_all(&root);
        let _ = fs::remove_dir_all(&outside);
        let _ = fs::remove_dir_all(&wt_sibling);
        let _ = fs::remove_dir_all(&wt_spoof);
    }

    #[test]
    fn before_command_is_provider_neutral_git_tripwire() {
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
            "B3_HOOK_ACTIVE=1 git commit -m x",
            "{ B3_HOOK_ACTIVE=1 git commit -m x; }",
            "env B3_HOOK_ACTIVE=1 git push origin main",
            "export B3_HOOK_ACTIVE=1",
            "B3_HOOK_MODE=off git commit -m x",
            "{ B3_HOOK_MODE=off git status; }",
            "env B3_HOOK_MODE=audit git push origin main",
            "export B3_HOOK_MODE=off",
        ] {
            assert!(
                matches!(
                    dispatch_event(&make_cmd_event(Some(&root_str), blocked), &cfg),
                    HookOutcome::Deny { .. }
                ),
                "expected Deny for `{blocked}`"
            );
        }

        for allowed in [
            "git status",
            "git push --force-with-lease origin feat",
            "git commit -m \"allow --no-verify in text\"",
            "git add src/hook/dispatch.rs",
            "echo 'git push --force'",
            "echo ${B3_HOOK_ACTIVE}",
            "echo B3_HOOK_ACTIVE=1",
            "echo B3_HOOK_MODE=off",
            "git grep B3_HOOK_ACTIVE=1",
            "git grep B3_HOOK_MODE=off",
            "# git reset --hard",
            "gh pr merge 42",
        ] {
            assert_eq!(
                dispatch_event(&make_cmd_event(Some(&root_str), allowed), &cfg),
                HookOutcome::Allow,
                "expected Allow for `{allowed}`"
            );
        }

        fs::remove_dir_all(root.join(".b3")).unwrap();
        assert_eq!(
            dispatch_event(&make_cmd_event(Some(&root_str), "git add -A"), &cfg),
            HookOutcome::Allow
        );

        let _ = fs::remove_dir_all(&root);
    }

    fn git_ok(dir: &Path, args: &[&str]) {
        let no_env: [(&str, &str); 0] = [];
        assert_eq!(run_git(dir, args, &no_env, None).unwrap().exit_code, 0);
    }

    #[test]
    fn before_commit_and_mode_error_handling() {
        let _lock = lock_hook_env();
        let _env = clear_hook_env();
        let repo = temp_dir("precommit_git");
        git_ok(&repo, &["init"]);
        git_ok(&repo, &["config", "user.email", "t@example.com"]);
        git_ok(&repo, &["config", "user.name", "Test"]);
        fs::write(repo.join("hello.txt"), "hi\n").unwrap();
        git_ok(&repo, &["add", "hello.txt"]);

        let repo_str = repo.to_string_lossy().into_owned();
        assert_eq!(
            run_hook("git", Some("pre-commit"), Some(&repo_str), None, "")
                .unwrap()
                .1,
            HookOutcome::Allow
        );

        // Staged secret must block (F01: canonical precommit runs)
        fs::write(repo.join(".env"), "SECRET=1\n").unwrap();
        git_ok(&repo, &["add", "-f", ".env"]);
        let (resp_sec, out_sec) =
            run_hook("git", Some("pre-commit"), Some(&repo_str), None, "").unwrap();
        assert!(matches!(out_sec, HookOutcome::Deny { .. }) && resp_sec.exit_code == 1);

        // Unstage .env; with B3_VERIFY_RECEIPT, staged != WT must block cleanly
        let no_env: [(&str, &str); 0] = [];
        let _ = run_git(&repo, &["reset", "HEAD", "--", ".env"], &no_env, None);
        let _ = fs::remove_file(repo.join(".env"));
        git_ok(&repo, &["commit", "-m", "init"]);
        fs::write(repo.join("hello.txt"), "v2\n").unwrap();
        let cmd = if cfg!(windows) {
            "cmd /c exit 0"
        } else {
            "true"
        };
        assert_eq!(
            crate::guard::verify::verify_run(
                &repo_str,
                cmd,
                ".b3/ship/verify/hook-unit.verify",
                "hook-unit",
                "hello.txt",
                "hello.txt",
                "",
                ""
            )
            .unwrap()
            .1,
            0
        );
        git_ok(&repo, &["add", "hello.txt"]);
        {
            let _rec = EnvGuard::new(&[(
                "B3_VERIFY_RECEIPT",
                Some(".b3/ship/verify/hook-unit.verify"),
            )]);
            assert_eq!(
                run_hook("git", Some("pre-commit"), Some(&repo_str), None, "")
                    .unwrap()
                    .1,
                HookOutcome::Allow
            );
            // Modify WT after verification -> same staged tree, changed WT -> MUST block
            fs::write(repo.join("hello.txt"), "v3 unstaged\n").unwrap();
            let (resp_wt, out_wt) =
                run_hook("git", Some("pre-commit"), Some(&repo_str), None, "").unwrap();
            assert!(matches!(out_wt, HookOutcome::Deny { .. }) && resp_wt.exit_code == 1);
        }

        // F05: audit / off handle malformed JSON without blocking
        let (resp_aud, out_aud) = run_hook(
            "cursor",
            Some("preToolUse"),
            Some(&repo_str),
            Some("audit"),
            "{bad",
        )
        .unwrap();
        assert_eq!(resp_aud.exit_code, 0);
        assert!(matches!(out_aud, HookOutcome::Advisory { .. }));
        let (resp_off, out_off) = run_hook(
            "cursor",
            Some("preToolUse"),
            Some(&repo_str),
            Some("off"),
            "{bad",
        )
        .unwrap();
        assert_eq!((resp_off.exit_code, out_off), (0, HookOutcome::Allow));
        let _ = fs::remove_dir_all(&repo);
    }

    #[test]
    fn after_write_and_completion_receipt_advisory() {
        let _lock = lock_hook_env();
        let _env = clear_hook_env();
        let dir = temp_dir("after_write");
        let dir_str = dir.to_string_lossy().into_owned();
        let payload = format!(
            r#"{{"hook_event_name":"afterFileEdit","file_path":"src/lib.rs","workspace_roots":["{}"]}}"#,
            dir_str.replace('\\', "/")
        );
        let (resp_clean, out_clean) =
            run_hook("cursor", None, Some(&dir_str), None, &payload).unwrap();
        assert_eq!(
            (out_clean, resp_clean.stdout.as_str()),
            (HookOutcome::Allow, "{}")
        );

        let _rec = EnvGuard::new(&[("B3_VERIFY_RECEIPT", Some(".b3/verify.receipt"))]);
        let (resp_adv, out_adv) = run_hook("cursor", None, Some(&dir_str), None, &payload).unwrap();
        assert!(
            matches!(out_adv, HookOutcome::Advisory { .. })
                && resp_adv.exit_code == 0
                && !resp_adv.stderr.is_empty()
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn upward_repo_discovery_respects_git_boundary() {
        let _lock = lock_hook_env();
        let _env = clear_hook_env();
        let base = temp_dir("upward_disc");
        let missing_personal = base.join("no_personal.md").to_string_lossy().into_owned();
        let _pers = EnvGuard::new(&[("B3_MODELS_PERSONAL", Some(&missing_personal))]);

        let outer = base.join("outer");
        let sub = outer.join("a/b");
        fs::create_dir_all(outer.join(".git")).unwrap();
        fs::create_dir_all(outer.join(".b3")).unwrap();
        fs::create_dir_all(&sub).unwrap();
        fs::write(
            outer.join(".b3/models.md"),
            "```yaml\nhooks:\n  enabled: true\n  mode: audit\n```\n",
        )
        .unwrap();

        let sub_str = sub.to_string_lossy().into_owned();
        assert_eq!(
            norm_cmp_path(&resolve_project_pref_path(&sub_str, false)),
            norm_cmp_path(&outer.join(".b3/models.md"))
        );
        assert_eq!(
            norm_cmp_path(&resolve_project_pref_path(&sub_str, true)),
            norm_cmp_path(&sub.join(".b3/config.toml"))
        );
        let (cfg, warnings) = resolve_cfg_for_root(Some((&sub_str, false)), None);
        assert!(warnings.is_empty());
        assert_eq!(cfg.effective_mode(), HookMode::Audit);

        // Nested repo with its own .git must stop at inner .git and not walk into outer .b3/models.md
        let nested = outer.join("nested");
        let nested_sub = nested.join("src");
        fs::create_dir_all(nested.join(".git")).unwrap();
        fs::create_dir_all(&nested_sub).unwrap();
        let nested_sub_str = nested_sub.to_string_lossy().into_owned();
        assert_eq!(
            norm_cmp_path(&resolve_project_pref_path(&nested_sub_str, false)),
            norm_cmp_path(&nested.join(".b3/config.toml"))
        );
        let (nested_cfg, _) = resolve_cfg_for_root(Some((&nested_sub_str, false)), None);
        assert_eq!(nested_cfg.effective_mode(), HookMode::Enforce);

        let _ = fs::remove_dir_all(&base);
    }
}
