pub mod config;
pub(crate) mod dispatch;
pub(crate) mod event;
pub(crate) mod install;
pub(crate) mod response;

pub(crate) fn norm_cmp_path(p: &std::path::Path) -> String {
    let s = crate::adapters::common::normalize_abs_path_str(p)
        .replace('\\', "/")
        .trim_end_matches('/')
        .to_string();
    if cfg!(windows) {
        s.to_ascii_lowercase()
    } else {
        s
    }
}

#[cfg(test)]
pub(crate) static HOOK_ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
