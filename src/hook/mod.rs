pub mod config;
pub mod dispatch;
pub mod event;
pub mod install;
pub mod response;

#[cfg(test)]
pub(crate) static HOOK_ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
