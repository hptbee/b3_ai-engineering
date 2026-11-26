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
                GuardSubcommand::Precommit {
                    repo_root,
                    allowed_paths,
                    require_verify_receipt,
                    ignore_dirty_paths,
                } => guard::precommit::run(
                    &repo_root,
                    &allowed_paths,
                    &require_verify_receipt,
                    &ignore_dirty_paths,
                )?,
                GuardSubcommand::VerifyRun {
                    repo_root,
                    verify_cmd,
                    receipt_path,
                    task_id,
                    scope,
                    relevant_paths,
                    ignore_dirty_paths,
                    log_path,
                } => {
                    return guard::verify::verify_run(
                        &repo_root,
                        &verify_cmd,
                        &receipt_path,
                        &task_id,
                        &scope,
                        &relevant_paths,
                        &ignore_dirty_paths,
                        &log_path,
                    );
                }
                GuardSubcommand::VerifyCheck {
                    repo_root,
                    receipt_path,
                    expected_cmd,
                    relevant_paths,
                    ignore_dirty_paths,
                    target_commit_sha,
                    has_target_commit_sha,
                } => {
                    return guard::verify::verify_check(
                        &repo_root,
                        &receipt_path,
                        &expected_cmd,
                        &relevant_paths,
                        &ignore_dirty_paths,
                        &target_commit_sha,
                        has_target_commit_sha,
                    );
                }
                GuardSubcommand::CheckWorktree {
                    repo_root,
                    expected_root,
                    expected_base_sha,
                    peer_roots,
                    require_isolated,
                } => guard::worktree::run(
                    &repo_root,
                    &expected_root,
                    &expected_base_sha,
                    &peer_roots,
                    require_isolated,
                )?,
            };
            Ok((out, 0))
        }
    }
}
