pub mod config;
pub(crate) mod dispatch;
pub(crate) mod event;
pub(crate) mod install;
pub(crate) mod response;

#[cfg(any(target_os = "macos", test))]
pub(crate) fn collapse_macos_private_prefix(s: &str) -> String {
    for prefix in ["/private/var", "/private/tmp"] {
        if s == prefix || s.starts_with(&format!("{prefix}/")) {
            return format!("/{}", &s["/private/".len()..]);
        }
    }
    s.to_string()
}

pub(crate) fn norm_cmp_path(p: &std::path::Path) -> String {
    let expanded = crate::fs::expand_windows_long_existing_prefix(p);
    let s = crate::adapters::common::normalize_abs_path_str(&expanded)
        .replace('\\', "/")
        .trim_end_matches('/')
        .to_string();
    #[cfg(target_os = "macos")]
    let s = collapse_macos_private_prefix(&s);
    if cfg!(windows) {
        s.to_ascii_lowercase()
    } else {
        s
    }
}

#[cfg(test)]
pub(crate) static HOOK_ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
