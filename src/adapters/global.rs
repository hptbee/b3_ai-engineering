use std::path::PathBuf;

use crate::adapters::{antigravity, common, cursor};
use crate::error::{fail, B3Error};

fn trim_child_path_arg(raw: &str) -> String {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    let b = trimmed.as_bytes();
    if b.len() >= 3
        && b[0].is_ascii_alphabetic()
        && b[1] == b':'
        && trimmed[2..].bytes().all(|c| c == b'/' || c == b'\\')
    {
        return format!("{}:/", b[0] as char);
    }
    if trimmed.bytes().all(|c| c == b'/' || c == b'\\') {
        return trimmed[..1].to_string();
    }
    trimmed.trim_end_matches(['\\', '/']).to_string()
}

/// Executes `b3 install global`.
#[allow(clippy::too_many_arguments)]
pub fn run(
    action_raw: &str,
    host_name_raw: &str,
    b3_home_raw: &str,
    cursor_home_raw: &str,
    plugin_root_raw: &str,
    user_home_raw: &str,
    dry_run: bool,
    force: bool,
) -> Result<(String, i32), B3Error> {
    let action = if action_raw.trim().is_empty() {
        "install"
    } else {
        action_raw.trim()
    };
    if !matches!(action, "install" | "update" | "verify" | "uninstall") {
        return Err(fail(format!("error: invalid action '{action}'"), 1));
    }
    let host_name = if host_name_raw.trim().is_empty() {
        "all"
    } else {
        host_name_raw.trim()
    };
    if !matches!(host_name, "cursor" | "antigravity" | "all") {
        return Err(fail(
            format!("error: invalid --host '{host_name}' (expected cursor, antigravity, or all)"),
            1,
        ));
    }

    let b3_home_arg = trim_child_path_arg(b3_home_raw);
    let cursor_home_arg = trim_child_path_arg(cursor_home_raw);
    let plugin_root_arg = trim_child_path_arg(plugin_root_raw);
    let user_home_arg = trim_child_path_arg(user_home_raw);

    let b3_home = common::resolve_b3_home_auto(&b3_home_arg)?;
    let b3_home_str = b3_home.to_string_lossy().into_owned();

    let mut out = Vec::new();
    let mut results: Vec<(&str, i32)> = Vec::new();
    let mut overall_exit = 0i32;

    if matches!(host_name, "cursor" | "all") {
        out.push(format!("=== [cursor] action={action} ==="));
        let (text, code) = match cursor::run(
            action,
            &cursor_home_arg,
            &b3_home_str,
            &user_home_arg,
            dry_run,
            force,
        ) {
            Ok((t, c)) => (t, c),
            Err(e) => (e.message, if e.code == 0 { 1 } else { e.code }),
        };
        if !text.is_empty() {
            out.push(text);
        }
        if code != 0 {
            overall_exit = 1;
        }
        results.push(("cursor", code));
    }

    if matches!(host_name, "antigravity" | "all") {
        out.push(format!("=== [antigravity] action={action} ==="));
        let (text, code) = match antigravity::run(
            action,
            &plugin_root_arg,
            &b3_home_str,
            &user_home_arg,
            dry_run,
            force,
        ) {
            Ok((t, c)) => (t, c),
            Err(e) => (e.message, if e.code == 0 { 1 } else { e.code }),
        };
        if !text.is_empty() {
            out.push(text);
        }
        if code != 0 {
            overall_exit = 1;
        }
        results.push(("antigravity", code));
    }

    for (h, code) in &results {
        let st = if *code == 0 { "OK" } else { "FAIL" };
        out.push(format!("host={h} status={st} exit={code}"));
    }

    if overall_exit != 0 {
        out.push(format!("GLOBAL_FAIL: host={host_name} action={action}"));
        return Ok((out.join("\n"), 1));
    }

    if matches!(action, "install" | "update") {
        let uh_opt = if user_home_arg.is_empty() {
            None
        } else {
            Some(PathBuf::from(common::normalize_path_str(&user_home_arg)?))
        };
        if let Ok(status) =
            common::initialize_personal_config_file(&b3_home, uh_opt.as_deref(), dry_run, true)
        {
            if let Some(msg) = common::format_personal_config_status(&b3_home, &status, false) {
                out.push(msg);
            }
        }
    }

    out.push(format!("GLOBAL_OK: host={host_name} action={action}"));
    Ok((out.join("\n"), 0))
}
