pub mod adapters;
pub mod cli;
pub mod context;
pub mod error;
pub mod fs;
pub mod git;
pub mod guard;
pub mod hook;
pub mod json;
pub mod pr;
pub mod process;

use std::io::Read;
use std::path::Path;

use cli::{
    help_text, parse_args, Command, GuardSubcommand, HookSubcommand, InstallSubcommand,
    PrSubcommand,
};
use error::B3Error;

/// Structured CLI output supporting separate `stdout`, `stderr`, and exit status.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CliOutput {
    pub stdout: String,
    pub stderr: String,
    pub exit_code: i32,
}

fn read_hook_stdin_bounded() -> Result<String, B3Error> {
    let limit = hook::event::MAX_HOOK_PAYLOAD_BYTES as u64 + 1;
    let mut buf = Vec::new();
    std::io::stdin()
        .take(limit)
        .read_to_end(&mut buf)
        .map_err(|e| error::fail(format!("HOOK_IO_FAIL: cannot read stdin: {e}"), 1))?;
    if buf.len() > hook::event::MAX_HOOK_PAYLOAD_BYTES {
        return Err(error::fail(
            format!(
                "HOOK_PAYLOAD_TOO_LARGE: stdin exceeds {} bytes",
                hook::event::MAX_HOOK_PAYLOAD_BYTES
            ),
            1,
        ));
    }
    String::from_utf8(buf)
        .map_err(|e| error::fail(format!("HOOK_INVALID_UTF8: invalid UTF-8 on stdin: {e}"), 1))
}

/// Executes a parsed `b3` CLI invocation with full `stdout`/`stderr` separation.
pub fn dispatch_args_io(raw_args: &[String]) -> Result<CliOutput, B3Error> {
    let cmd = parse_args(raw_args)?;
    if let Command::Hook(HookSubcommand::Run {
        host,
        event,
        repo_root,
        mode,
        payload,
    }) = cmd
    {
        let ev_opt = if event.trim().is_empty() {
            None
        } else {
            Some(event.as_str())
        };
        let rr_opt = if repo_root.trim().is_empty() {
            None
        } else {
            Some(repo_root.as_str())
        };
        let mode_opt = if mode.trim().is_empty() {
            None
        } else {
            Some(mode.as_str())
        };
        let body = match payload {
            Some(p) => p,
            None => match read_hook_stdin_bounded() {
                Ok(s) => s,
                Err(e) => {
                    if let Some(resp) =
                        hook::dispatch::fail_closed_host_response(&host, ev_opt, &e.message)
                    {
                        return Ok(CliOutput {
                            stdout: resp.stdout,
                            stderr: resp.stderr,
                            exit_code: resp.exit_code,
                        });
                    }
                    return Err(e);
                }
            },
        };
        match hook::dispatch::run_hook(&host, ev_opt, rr_opt, mode_opt, &body) {
            Ok((resp, _)) => {
                return Ok(CliOutput {
                    stdout: resp.stdout,
                    stderr: resp.stderr,
                    exit_code: resp.exit_code,
                });
            }
            Err(e) => {
                if let Some(resp) =
                    hook::dispatch::fail_closed_host_response(&host, ev_opt, &e.message)
                {
                    return Ok(CliOutput {
                        stdout: resp.stdout,
                        stderr: resp.stderr,
                        exit_code: resp.exit_code,
                    });
                }
                return Err(e);
            }
        }
    }
    let (stdout, exit_code) = dispatch_parsed(cmd)?;
    Ok(CliOutput {
        stdout,
        stderr: String::new(),
        exit_code,
    })
}

/// Executes a parsed `b3` CLI invocation and returns `(stdout_text, exit_code)`.
pub fn dispatch_args(raw_args: &[String]) -> Result<(String, i32), B3Error> {
    let cmd = parse_args(raw_args)?;
    dispatch_parsed(cmd)
}

fn dispatch_parsed(cmd: Command) -> Result<(String, i32), B3Error> {
    match cmd {
        Command::Version => Ok((format!("b3 {}", env!("CARGO_PKG_VERSION")), 0)),
        Command::Help => Ok((help_text().to_string(), 0)),
        Command::ContextMeasure { repo_root, strict } => {
            context::measure_context(&repo_root, strict)
        }
        Command::Sync {
            repo_root,
            host_name,
            dry_run,
            verify_only,
            force,
        } => adapters::sync::run(&repo_root, &host_name, dry_run, verify_only, force),
        Command::Install(inst_cmd) => match inst_cmd {
            InstallSubcommand::Product {
                product_root,
                b3_home,
                host_name,
                dry_run,
                force,
            } => adapters::product::run(&product_root, &b3_home, &host_name, dry_run, force),
            InstallSubcommand::Cursor {
                action,
                cursor_home,
                b3_home,
                user_home,
                dry_run,
                force,
            } => adapters::cursor::run(&action, &cursor_home, &b3_home, &user_home, dry_run, force),
            InstallSubcommand::Antigravity {
                action,
                plugin_root,
                b3_home,
                user_home,
                dry_run,
                force,
            } => adapters::antigravity::run(
                &action,
                &plugin_root,
                &b3_home,
                &user_home,
                dry_run,
                force,
            ),
            InstallSubcommand::Global {
                action,
                host_name,
                b3_home,
                cursor_home,
                plugin_root,
                user_home,
                dry_run,
                force,
            } => adapters::global::run(
                &action,
                &host_name,
                &b3_home,
                &cursor_home,
                &plugin_root,
                &user_home,
                dry_run,
                force,
            ),
        },
        Command::Pr(pr_cmd) => match pr_cmd {
            PrSubcommand::Verify {
                mode,
                repo_root,
                has_repo_root,
                repo,
                pr_number,
                gh_bin,
                bash_bin,
            } => pr::verify::run(
                &mode,
                &repo_root,
                has_repo_root,
                &repo,
                &pr_number,
                &gh_bin,
                &bash_bin,
            ),
            PrSubcommand::Github { subcommand, args } => pr::github::run(&subcommand, &args),
        },
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
                    expected_cmd,
                    relevant_paths,
                } => guard::precommit::run(
                    &repo_root,
                    &allowed_paths,
                    &require_verify_receipt,
                    &ignore_dirty_paths,
                    &expected_cmd,
                    &relevant_paths,
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
                    active_specs,
                    active_reads,
                    verified_dirty_paths,
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
                        &active_specs,
                        &active_reads,
                        &verified_dirty_paths,
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
                    worker_bases,
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
                        &worker_bases,
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
                GuardSubcommand::EvidenceCheck {
                    repo_root,
                    source_paths,
                    manifest_path,
                    write_manifest,
                } => {
                    return guard::evidence::run(
                        &repo_root,
                        &source_paths,
                        &manifest_path,
                        write_manifest,
                    );
                }
                GuardSubcommand::MergePolicyCheck {
                    repo_root,
                    policy_path,
                    pr_state,
                    ci_status,
                    review_status,
                    blocking_findings,
                    governance_status,
                    changed_paths,
                    post_merge,
                    merged_sha,
                    main_ref,
                    target_ref,
                    authority_ref,
                    base_sha,
                    head_sha,
                    ledger_path,
                    receipt_path,
                    ignore_dirty_paths,
                    pr_number,
                    repo,
                    target_branch,
                    local_only,
                    require_remote_ci,
                } => {
                    return guard::merge_policy::run(
                        &repo_root,
                        &policy_path,
                        pr_state.as_deref(),
                        ci_status.as_deref(),
                        review_status.as_deref(),
                        blocking_findings,
                        &governance_status,
                        &changed_paths,
                        post_merge,
                        &merged_sha,
                        &main_ref,
                        &target_ref,
                        &authority_ref,
                        &base_sha,
                        &head_sha,
                        &ledger_path,
                        &receipt_path,
                        &ignore_dirty_paths,
                        &pr_number,
                        &repo,
                        &target_branch,
                        local_only,
                        require_remote_ci,
                    );
                }
            };
            Ok((out, 0))
        }
        Command::Hook(hook_cmd) => match hook_cmd {
            HookSubcommand::Run {
                host,
                event,
                repo_root,
                mode,
                payload,
            } => {
                let body = match payload {
                    Some(p) => p,
                    None => read_hook_stdin_bounded()?,
                };
                let (resp, _) = hook::dispatch::run_hook(
                    &host,
                    if event.trim().is_empty() {
                        None
                    } else {
                        Some(event.as_str())
                    },
                    if repo_root.trim().is_empty() {
                        None
                    } else {
                        Some(repo_root.as_str())
                    },
                    if mode.trim().is_empty() {
                        None
                    } else {
                        Some(mode.as_str())
                    },
                    &body,
                )?;
                let text = if !resp.stdout.is_empty() {
                    resp.stdout
                } else {
                    resp.stderr
                };
                Ok((text, resp.exit_code))
            }
            HookSubcommand::Install {
                host,
                scope,
                repo_root,
                user_home,
                b3_bin,
                dry_run,
                force,
            } => {
                let h = hook::install::HookHostTarget::parse(&host)?;
                let s = hook::install::HookScope::parse(&scope)?;
                let rr = if repo_root.trim().is_empty() {
                    None
                } else {
                    Some(Path::new(repo_root.trim()))
                };
                let uh = if user_home.trim().is_empty() {
                    None
                } else {
                    Some(Path::new(user_home.trim()))
                };
                let bb = if b3_bin.trim().is_empty() {
                    None
                } else {
                    Some(b3_bin.trim())
                };
                hook::install::install_hooks(h, s, rr, uh, bb, dry_run, force)
            }
            HookSubcommand::Uninstall {
                host,
                scope,
                repo_root,
                user_home,
                dry_run,
            } => {
                let h = hook::install::HookHostTarget::parse(&host)?;
                let s = hook::install::HookScope::parse(&scope)?;
                let rr = if repo_root.trim().is_empty() {
                    None
                } else {
                    Some(Path::new(repo_root.trim()))
                };
                let uh = if user_home.trim().is_empty() {
                    None
                } else {
                    Some(Path::new(user_home.trim()))
                };
                hook::install::uninstall_hooks(h, s, rr, uh, dry_run)
            }
            HookSubcommand::Verify {
                host,
                scope,
                repo_root,
                user_home,
            } => {
                let h = hook::install::HookHostTarget::parse(&host)?;
                let s = hook::install::HookScope::parse(&scope)?;
                let rr = if repo_root.trim().is_empty() {
                    None
                } else {
                    Some(Path::new(repo_root.trim()))
                };
                let uh = if user_home.trim().is_empty() {
                    None
                } else {
                    Some(Path::new(user_home.trim()))
                };
                hook::install::verify_hooks(h, s, rr, uh)
            }
            HookSubcommand::Status {
                repo_root,
                user_home,
            } => {
                let rr = if repo_root.trim().is_empty() {
                    None
                } else {
                    Some(Path::new(repo_root.trim()))
                };
                let uh = if user_home.trim().is_empty() {
                    None
                } else {
                    Some(Path::new(user_home.trim()))
                };
                hook::install::status_hooks(rr, uh)
            }
        },
    }
}
