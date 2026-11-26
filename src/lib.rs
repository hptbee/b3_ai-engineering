pub mod cli;
pub mod context;
pub mod error;
pub mod fs;
pub mod git;
pub mod guard;
pub mod process;

use cli::{help_text, parse_args, Command, GuardSubcommand};
use error::B3Error;

/// Executes a parsed `b3` CLI invocation and returns `(stdout_text, exit_code)`.
pub fn dispatch_args(raw_args: &[String]) -> Result<(String, i32), B3Error> {
    let cmd = parse_args(raw_args)?;
    match cmd {
        Command::Version => Ok((format!("b3 {}", env!("CARGO_PKG_VERSION")), 0)),
        Command::Help => Ok((help_text().to_string(), 0)),
        Command::ContextMeasure { repo_root, strict } => {
            context::measure_context(&repo_root, strict)
        }
        Command::Guard(sub) => {
            let out = match sub {
                GuardSubcommand::Fingerprint {
                    depends_on,
                    scope,
                    criteria,
                } => guard::fingerprint::run(&depends_on, &scope, &criteria)?,
                GuardSubcommand::CheckFreshness {
                    repo_root,
                    approach_at_sha,
                    task_base_sha,
                    watched_paths,
                    owned_files,
                    ignore_dirty_paths,
                } => guard::freshness::run(
                    &repo_root,
                    &approach_at_sha,
                    &task_base_sha,
                    &watched_paths,
                    &owned_files,
                    &ignore_dirty_paths,
                )?,
                GuardSubcommand::Snapshot { repo_root } => guard::snapshot::run(&repo_root)?,
                GuardSubcommand::NewRun {
                    repo_root,
                    slug,
                    timestamp,
                    namespace,
                } => guard::runs::new_run(&repo_root, &slug, &timestamp, &namespace)?,
                GuardSubcommand::ResolveRun {
                    repo_root,
                    run_id,
                    namespace,
                } => guard::runs::resolve_run(&repo_root, &run_id, &namespace)?,
                GuardSubcommand::ListRuns {
                    repo_root,
                    namespace,
                } => guard::runs::list_runs(&repo_root, &namespace)?,
                GuardSubcommand::Prune {
                    repo_root,
                    keep,
                    namespace,
                } => guard::runs::prune(&repo_root, keep, &namespace)?,
            };
            Ok((out, 0))
        }
    }
}
