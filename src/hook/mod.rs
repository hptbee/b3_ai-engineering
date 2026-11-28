pub mod config;
pub mod dispatch;
pub mod event;
pub mod install;
pub mod response;

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
