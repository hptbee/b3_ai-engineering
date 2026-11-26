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
                GuardSubcommand::CheckWave {
                    repo_root,
                    wave_specs,
                    wave_reads,
                    expected_base_sha,
                    max_concurrency,
                    partition,
                    protected_paths,
                    check_dirty_scope,
                    ignore_dirty_paths,
                } => {
                    return guard::wave::run(
                        &repo_root,
                        &wave_specs,
                        &wave_reads,
                        &expected_base_sha,
                        max_concurrency,
                        partition,
                        &protected_paths,
                        check_dirty_scope,
                        &ignore_dirty_paths,
                    );
                }
                GuardSubcommand::SymbolCheck {
                    repo_root,
                    base_sha,
                    target_ref,
                    ignore_dirty_paths,
                } => {
                    return guard::symbol::run(
                        &repo_root,
                        &base_sha,
                        &target_ref,
                        &ignore_dirty_paths,
                    );
                }
                GuardSubcommand::DiffScope {
                    repo_root,
                    base_sha,
                    prev_sha,
                    target_ref,
                    ignore_dirty_paths,
                } => {
                    return guard::scope::run_diff_scope(
                        &repo_root,
                        &base_sha,
                        &prev_sha,
                        &target_ref,
                        &ignore_dirty_paths,
                    );
                }
                GuardSubcommand::MechanicalCheck {
                    repo_root,
                    base_sha,
                    target_ref,
                    allowed_paths,
                    ignore_dirty_paths,
                    obsoletes,
                    allow_mass_delete,
                    wave_specs,
                    worker_changes,
                    worker_roots,
                    protected_paths,
                    dirty_digests,
                    has_dirty_digests,
                } => {
                    return guard::mechanical::run(
                        &repo_root,
                        &base_sha,
                        &target_ref,
                        &allowed_paths,
                        &ignore_dirty_paths,
                        &obsoletes,
                        allow_mass_delete,
                        &wave_specs,
                        &worker_changes,
                        &worker_roots,
                        &protected_paths,
                        &dirty_digests,
                        has_dirty_digests,
                    );
                }
                GuardSubcommand::ReviewInventory {
                    repo_root,
                    base_sha,
                    target_ref,
                    ignore_dirty_paths,
                    max_concurrency,
                } => {
                    return guard::inventory::run(
                        &repo_root,
                        &base_sha,
                        &target_ref,
                        &ignore_dirty_paths,
                        max_concurrency,
                    );
                }
                GuardSubcommand::ReviewLedger {
                    repo_root,
                    action,
                    ledger_path,
                    base_sha,
                    target_ref,
                    ignore_dirty_paths,
                    max_concurrency,
                    max_passes,
                    unit_id,
                    status,
                    findings,
                    specialists,
                    rationale,
                    receipt_path,
                    cross_unit_status,
                    budget_status,
                    review_independence,
                    passes_used,
                    scope,
                    force,
                } => {
                    return guard::ledger::run(
                        &repo_root,
                        &action,
                        &ledger_path,
                        &base_sha,
                        &target_ref,
                        &ignore_dirty_paths,
                        max_concurrency,
                        max_passes,
                        &unit_id,
                        &status,
                        &findings,
                        &specialists,
                        &rationale,
                        &receipt_path,
                        &cross_unit_status,
                        &budget_status,
                        &review_independence,
                        passes_used,
                        &scope,
                        force,
                    );
                }
                GuardSubcommand::ContextCache {
                    repo_root,
                    action,
                    cache_path,
                    scope_id,
                    anchor_paths,
                    scope_paths,
                    graph_index_sha,
                    summary_ref,
                    ignore_dirty_paths,
                } => {
                    return guard::cache::run(
                        &repo_root,
                        &action,
                        &cache_path,
                        &scope_id,
                        &anchor_paths,
                        &scope_paths,
                        &graph_index_sha,
                        &summary_ref,
                        &ignore_dirty_paths,
                    );
                }
            };
            Ok((out, 0))
        }
    }
}
