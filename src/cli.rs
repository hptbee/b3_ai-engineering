use crate::error::{fail, B3Error};

#[derive(Debug, Clone, PartialEq, Eq)]
#[allow(clippy::large_enum_variant)]
pub enum Command {
    Version,
    Help,
    ContextMeasure { repo_root: String, strict: bool },
    Guard(GuardSubcommand),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GuardSubcommand {
    Fingerprint {
        depends_on: String,
        scope: String,
        criteria: Vec<String>,
    },
    CheckFreshness {
        repo_root: String,
        approach_at_sha: String,
        task_base_sha: String,
        watched_paths: String,
        owned_files: String,
        ignore_dirty_paths: String,
    },
    Snapshot {
        repo_root: String,
    },
    NewRun {
        repo_root: String,
        slug: String,
        timestamp: String,
        namespace: String,
    },
    ResolveRun {
        repo_root: String,
        run_id: String,
        namespace: String,
    },
    ListRuns {
        repo_root: String,
        namespace: String,
    },
    Prune {
        repo_root: String,
        keep: i32,
        namespace: String,
    },
    Precommit {
        repo_root: String,
        allowed_paths: String,
        require_verify_receipt: String,
        ignore_dirty_paths: String,
    },
    VerifyRun {
        repo_root: String,
        verify_cmd: String,
        receipt_path: String,
        task_id: String,
        scope: String,
        relevant_paths: String,
        ignore_dirty_paths: String,
        log_path: String,
    },
    VerifyCheck {
        repo_root: String,
        receipt_path: String,
        expected_cmd: String,
        relevant_paths: String,
        ignore_dirty_paths: String,
        target_commit_sha: String,
        has_target_commit_sha: bool,
    },
    CheckWorktree {
        repo_root: String,
        expected_root: String,
        expected_base_sha: String,
        peer_roots: String,
        require_isolated: bool,
    },
    CheckWave {
        repo_root: String,
        wave_specs: String,
        wave_reads: String,
        expected_base_sha: String,
        max_concurrency: i32,
        partition: bool,
        protected_paths: String,
        check_dirty_scope: bool,
        ignore_dirty_paths: String,
    },
    SymbolCheck {
        repo_root: String,
        base_sha: String,
        target_ref: String,
        ignore_dirty_paths: String,
    },
    DiffScope {
        repo_root: String,
        base_sha: String,
        prev_sha: String,
        target_ref: String,
        ignore_dirty_paths: String,
    },
    MechanicalCheck {
        repo_root: String,
        base_sha: String,
        target_ref: String,
        allowed_paths: String,
        ignore_dirty_paths: String,
        obsoletes: String,
        allow_mass_delete: bool,
        wave_specs: String,
        worker_changes: String,
        worker_roots: String,
        protected_paths: String,
        dirty_digests: String,
        has_dirty_digests: bool,
    },
    ReviewInventory {
        repo_root: String,
        base_sha: String,
        target_ref: String,
        ignore_dirty_paths: String,
        max_concurrency: i32,
    },
    ReviewLedger {
        repo_root: String,
        action: String,
        ledger_path: String,
        base_sha: String,
        target_ref: String,
        ignore_dirty_paths: String,
        max_concurrency: i32,
        max_passes: Option<i64>,
        unit_id: String,
        status: String,
        findings: String,
        specialists: String,
        rationale: String,
        receipt_path: String,
        cross_unit_status: String,
        budget_status: String,
        review_independence: String,
        passes_used: Option<i64>,
        scope: String,
        force: bool,
    },
    ContextCache {
        repo_root: String,
        action: String,
        cache_path: String,
        scope_id: String,
        anchor_paths: String,
        scope_paths: String,
        graph_index_sha: String,
        summary_ref: String,
        ignore_dirty_paths: String,
    },
    EvidenceCheck {
        repo_root: String,
        source_paths: String,
        manifest_path: String,
        write_manifest: bool,
    },
    MergePolicyCheck {
        repo_root: String,
        policy_path: String,
        pr_state: Option<String>,
        ci_status: Option<String>,
        review_status: Option<String>,
        blocking_findings: i32,
        governance_status: String,
        changed_paths: String,
        post_merge: bool,
        merged_sha: String,
        main_ref: String,
        target_ref: String,
        authority_ref: String,
        base_sha: String,
        head_sha: String,
        ledger_path: String,
        receipt_path: String,
        ignore_dirty_paths: String,
        pr_number: String,
        repo: String,
        target_branch: String,
        local_only: bool,
        require_remote_ci: bool,
    },
}

pub fn help_text() -> &'static str {
    "\
b3 - B3 AI Engineering deterministic native core

USAGE:
  b3 --version | --help
  b3 context measure [--repo-root <path>] [--strict]
  b3 guard <subcommand> [flags]

GUARD SUBCOMMANDS:
  fingerprint       Compute canonical task/step fingerprint
  check-freshness   Verify HEAD & working tree freshness vs approach/base SHAs
  snapshot          Create snapshot commit excluding .b3 checkpoint dirs
  precommit         Validate staged index, allowed paths, secrets, and verify receipts
  verify-run        Execute verification command and write b3-verify-v1 receipt
  verify-check      Validate b3-verify-v1 receipt against working tree or target commit
  check-worktree    Validate worktree identity, isolation, and peer non-overlap
  check-wave        Validate wave task ownership conflicts, reads, and partition plan
  symbol-check      Detect removed symbols with dangling refs or orphan internal symbols
  diff-scope        Classify T-shirt size, changed/noise files, delta files, and risk signals
  mechanical-check  Run mechanical scope, leftover, obsolete, safety, and ownership gates
  review-inventory  Build scope inventory, specialists dispatch, and cohesive review units
  review-ledger     Manage tamper-evident b3-review-ledger-v1 coverage state and pass chain
  context-cache     Record and verify b3-context-v1 anchor/graph/summary cache freshness
  evidence-check    Write or validate SHA-256 b3-evidence-v1 manifests
  merge-policy-check Enforce provider-neutral pre-merge and post-merge governance policy
  new-run           Create a timestamped run directory and update CURRENT
  resolve-run       Resolve active or named run path
  list-runs         List runs for a namespace
  prune             Prune older PASS runs keeping the newest N"
}

fn parse_opt(arg: &str) -> (&str, Option<&str>) {
    if let Some((flag, val)) = arg.split_once('=') {
        if flag.starts_with("--") {
            return (flag, Some(val));
        }
    }
    (arg, None)
}

fn take_val(
    args: &[String],
    idx: &mut usize,
    opt: &str,
    inline_val: Option<&str>,
    err_prefix: &str,
) -> Result<String, B3Error> {
    if let Some(v) = inline_val {
        return Ok(v.to_string());
    }
    if *idx + 1 >= args.len() {
        return Err(fail(format!("{err_prefix}: missing value for {opt}"), 1));
    }
    *idx += 1;
    Ok(args[*idx].clone())
}

pub fn parse_args(args: &[String]) -> Result<Command, B3Error> {
    if args.is_empty() {
        return Ok(Command::Help);
    }
    match args[0].as_str() {
        "-V" | "--version" => Ok(Command::Version),
        "-h" | "--help" | "help" => Ok(Command::Help),
        "context" => parse_context(&args[1..]),
        "guard" => parse_guard(&args[1..]).map(Command::Guard),
        other => Err(fail(format!("B3_CLI_FAIL: unknown command '{other}'"), 1)),
    }
}

fn parse_context(args: &[String]) -> Result<Command, B3Error> {
    if args.is_empty() || args[0] != "measure" {
        return Err(fail(
            "CONTEXT_FAIL: expected `b3 context measure [--repo-root <path>] [--strict]`",
            1,
        ));
    }
    let mut repo_root = ".".to_string();
    let mut strict = false;
    let mut i = 1;
    while i < args.len() {
        let (flag, iv) = parse_opt(&args[i]);
        match flag {
            "--repo-root" => repo_root = take_val(args, &mut i, "--repo-root", iv, "CONTEXT_FAIL")?,
            "--strict" if iv.is_none() => strict = true,
            other => return Err(fail(format!("CONTEXT_FAIL: unknown option '{other}'"), 1)),
        }
        i += 1;
    }
    Ok(Command::ContextMeasure { repo_root, strict })
}

fn parse_guard(args: &[String]) -> Result<GuardSubcommand, B3Error> {
    if args.is_empty() {
        return Err(fail("GUARD_FAIL: missing guard subcommand", 1));
    }
    let sub = args[0].as_str();
    let rest = &args[1..];
    match sub {
        "fingerprint" => {
            let mut depends_on = String::new();
            let mut scope = String::new();
            let mut criteria = Vec::new();
            let mut i = 0;
            while i < rest.len() {
                let (flag, iv) = parse_opt(&rest[i]);
                match flag {
                    "--depends-on" => {
                        depends_on =
                            take_val(rest, &mut i, "--depends-on", iv, "FINGERPRINT_FAIL")?;
                    }
                    "--scope" => {
                        scope = take_val(rest, &mut i, "--scope", iv, "FINGERPRINT_FAIL")?;
                    }
                    "--criteria" | "--criterion" => {
                        criteria.push(take_val(rest, &mut i, flag, iv, "FINGERPRINT_FAIL")?);
                    }
                    other => {
                        return Err(fail(
                            format!("FINGERPRINT_FAIL: unknown option '{other}'"),
                            1,
                        ));
                    }
                }
                i += 1;
            }
            Ok(GuardSubcommand::Fingerprint {
                depends_on,
                scope,
                criteria,
            })
        }
        "check-freshness" => {
            let mut repo_root = ".".to_string();
            let mut approach_at_sha = String::new();
            let mut task_base_sha = String::new();
            let mut watched_paths = String::new();
            let mut owned_files = String::new();
            let mut ignore_dirty_paths = String::new();
            let mut i = 0;
            while i < rest.len() {
                let (flag, iv) = parse_opt(&rest[i]);
                match flag {
                    "--repo-root" => {
                        repo_root = take_val(rest, &mut i, "--repo-root", iv, "FRESHNESS_FAIL")?;
                    }
                    "--approach-at-sha" => {
                        approach_at_sha =
                            take_val(rest, &mut i, "--approach-at-sha", iv, "FRESHNESS_FAIL")?;
                    }
                    "--task-base-sha" => {
                        task_base_sha =
                            take_val(rest, &mut i, "--task-base-sha", iv, "FRESHNESS_FAIL")?;
                    }
                    "--watched-paths" => {
                        watched_paths =
                            take_val(rest, &mut i, "--watched-paths", iv, "FRESHNESS_FAIL")?;
                    }
                    "--owned-files" => {
                        owned_files =
                            take_val(rest, &mut i, "--owned-files", iv, "FRESHNESS_FAIL")?;
                    }
                    "--ignore-dirty-paths" => {
                        ignore_dirty_paths =
                            take_val(rest, &mut i, "--ignore-dirty-paths", iv, "FRESHNESS_FAIL")?;
                    }
                    other => {
                        return Err(fail(format!("FRESHNESS_FAIL: unknown option '{other}'"), 1));
                    }
                }
                i += 1;
            }
            Ok(GuardSubcommand::CheckFreshness {
                repo_root,
                approach_at_sha,
                task_base_sha,
                watched_paths,
                owned_files,
                ignore_dirty_paths,
            })
        }
        "snapshot" => {
            let mut repo_root = ".".to_string();
            let mut i = 0;
            while i < rest.len() {
                let (flag, iv) = parse_opt(&rest[i]);
                match flag {
                    "--repo-root" => {
                        repo_root = take_val(rest, &mut i, "--repo-root", iv, "SNAPSHOT_FAIL")?;
                    }
                    other => {
                        return Err(fail(format!("SNAPSHOT_FAIL: unknown option '{other}'"), 1));
                    }
                }
                i += 1;
            }
            Ok(GuardSubcommand::Snapshot { repo_root })
        }
        "new-run" => {
            let mut repo_root = ".".to_string();
            let mut slug = String::new();
            let mut timestamp = String::new();
            let mut namespace = "ship".to_string();
            let mut i = 0;
            while i < rest.len() {
                let (flag, iv) = parse_opt(&rest[i]);
                match flag {
                    "--repo-root" => {
                        repo_root = take_val(rest, &mut i, "--repo-root", iv, "NEW_RUN_FAIL")?;
                    }
                    "--slug" => {
                        slug = take_val(rest, &mut i, "--slug", iv, "NEW_RUN_FAIL")?;
                    }
                    "--timestamp" => {
                        timestamp = take_val(rest, &mut i, "--timestamp", iv, "NEW_RUN_FAIL")?;
                    }
                    "--namespace" => {
                        namespace = take_val(rest, &mut i, "--namespace", iv, "NEW_RUN_FAIL")?;
                    }
                    other => {
                        return Err(fail(format!("NEW_RUN_FAIL: unknown option '{other}'"), 1));
                    }
                }
                i += 1;
            }
            Ok(GuardSubcommand::NewRun {
                repo_root,
                slug,
                timestamp,
                namespace,
            })
        }
        "resolve-run" => {
            let mut repo_root = ".".to_string();
            let mut run_id = String::new();
            let mut namespace = "ship".to_string();
            let mut i = 0;
            while i < rest.len() {
                let (flag, iv) = parse_opt(&rest[i]);
                match flag {
                    "--repo-root" => {
                        repo_root = take_val(rest, &mut i, "--repo-root", iv, "RESOLVE_FAIL")?;
                    }
                    "--run-id" => {
                        run_id = take_val(rest, &mut i, "--run-id", iv, "RESOLVE_FAIL")?;
                    }
                    "--namespace" => {
                        namespace = take_val(rest, &mut i, "--namespace", iv, "RESOLVE_FAIL")?;
                    }
                    other => {
                        return Err(fail(format!("RESOLVE_FAIL: unknown option '{other}'"), 1));
                    }
                }
                i += 1;
            }
            Ok(GuardSubcommand::ResolveRun {
                repo_root,
                run_id,
                namespace,
            })
        }
        "list-runs" => {
            let mut repo_root = ".".to_string();
            let mut namespace = "ship".to_string();
            let mut i = 0;
            while i < rest.len() {
                let (flag, iv) = parse_opt(&rest[i]);
                match flag {
                    "--repo-root" => {
                        repo_root = take_val(rest, &mut i, "--repo-root", iv, "LIST_FAIL")?;
                    }
                    "--namespace" => {
                        namespace = take_val(rest, &mut i, "--namespace", iv, "LIST_FAIL")?;
                    }
                    other => {
                        return Err(fail(format!("LIST_FAIL: unknown option '{other}'"), 1));
                    }
                }
                i += 1;
            }
            Ok(GuardSubcommand::ListRuns {
                repo_root,
                namespace,
            })
        }
        "prune" => {
            let mut repo_root = ".".to_string();
            let mut keep = 10i32;
            let mut namespace = "ship".to_string();
            let mut i = 0;
            while i < rest.len() {
                let (flag, iv) = parse_opt(&rest[i]);
                match flag {
                    "--repo-root" => {
                        repo_root = take_val(rest, &mut i, "--repo-root", iv, "PRUNE_FAIL")?;
                    }
                    "--keep" => {
                        let raw = take_val(rest, &mut i, "--keep", iv, "PRUNE_FAIL")?;
                        keep = raw
                            .trim()
                            .parse::<i32>()
                            .map_err(|_| fail("PRUNE_FAIL: --keep must be an integer >= 0", 1))?;
                    }
                    "--namespace" => {
                        namespace = take_val(rest, &mut i, "--namespace", iv, "PRUNE_FAIL")?;
                    }
                    other => {
                        return Err(fail(format!("PRUNE_FAIL: unknown option '{other}'"), 1));
                    }
                }
                i += 1;
            }
            Ok(GuardSubcommand::Prune {
                repo_root,
                keep,
                namespace,
            })
        }
        "precommit" => {
            let mut repo_root = ".".to_string();
            let mut allowed_paths = String::new();
            let mut require_verify_receipt = String::new();
            let mut ignore_dirty_paths = String::new();
            let mut i = 0;
            while i < rest.len() {
                let (flag, iv) = parse_opt(&rest[i]);
                match flag {
                    "--repo-root" => {
                        repo_root = take_val(rest, &mut i, "--repo-root", iv, "PRECOMMIT_FAIL")?;
                    }
                    "--allowed-paths" => {
                        allowed_paths =
                            take_val(rest, &mut i, "--allowed-paths", iv, "PRECOMMIT_FAIL")?;
                    }
                    "--require-verify-receipt" => {
                        require_verify_receipt = take_val(
                            rest,
                            &mut i,
                            "--require-verify-receipt",
                            iv,
                            "PRECOMMIT_FAIL",
                        )?;
                    }
                    "--ignore-dirty-paths" => {
                        ignore_dirty_paths =
                            take_val(rest, &mut i, "--ignore-dirty-paths", iv, "PRECOMMIT_FAIL")?;
                    }
                    other => {
                        return Err(fail(format!("PRECOMMIT_FAIL: unknown option '{other}'"), 1));
                    }
                }
                i += 1;
            }
            Ok(GuardSubcommand::Precommit {
                repo_root,
                allowed_paths,
                require_verify_receipt,
                ignore_dirty_paths,
            })
        }
        "verify-run" => {
            let mut repo_root = ".".to_string();
            let mut verify_cmd = String::new();
            let mut receipt_path = String::new();
            let mut task_id = String::new();
            let mut scope = String::new();
            let mut relevant_paths = String::new();
            let mut ignore_dirty_paths = String::new();
            let mut log_path = String::new();
            let mut i = 0;
            while i < rest.len() {
                let (flag, iv) = parse_opt(&rest[i]);
                match flag {
                    "--repo-root" => {
                        repo_root = take_val(rest, &mut i, "--repo-root", iv, "VERIFY_RUN_FAIL")?;
                    }
                    "--verify-cmd" => {
                        verify_cmd = take_val(rest, &mut i, "--verify-cmd", iv, "VERIFY_RUN_FAIL")?;
                    }
                    "--receipt-path" => {
                        receipt_path =
                            take_val(rest, &mut i, "--receipt-path", iv, "VERIFY_RUN_FAIL")?;
                    }
                    "--task-id" => {
                        task_id = take_val(rest, &mut i, "--task-id", iv, "VERIFY_RUN_FAIL")?;
                    }
                    "--scope" => {
                        scope = take_val(rest, &mut i, "--scope", iv, "VERIFY_RUN_FAIL")?;
                    }
                    "--relevant-paths" => {
                        relevant_paths =
                            take_val(rest, &mut i, "--relevant-paths", iv, "VERIFY_RUN_FAIL")?;
                    }
                    "--ignore-dirty-paths" => {
                        ignore_dirty_paths =
                            take_val(rest, &mut i, "--ignore-dirty-paths", iv, "VERIFY_RUN_FAIL")?;
                    }
                    "--log-path" => {
                        log_path = take_val(rest, &mut i, "--log-path", iv, "VERIFY_RUN_FAIL")?;
                    }
                    other => {
                        return Err(fail(
                            format!("VERIFY_RUN_FAIL: unknown option '{other}'"),
                            1,
                        ));
                    }
                }
                i += 1;
            }
            Ok(GuardSubcommand::VerifyRun {
                repo_root,
                verify_cmd,
                receipt_path,
                task_id,
                scope,
                relevant_paths,
                ignore_dirty_paths,
                log_path,
            })
        }
        "verify-check" => {
            let mut repo_root = ".".to_string();
            let mut receipt_path = String::new();
            let mut expected_cmd = String::new();
            let mut relevant_paths = String::new();
            let mut ignore_dirty_paths = String::new();
            let mut target_commit_sha = String::new();
            let mut has_target_commit_sha = false;
            let mut i = 0;
            while i < rest.len() {
                let (flag, iv) = parse_opt(&rest[i]);
                match flag {
                    "--repo-root" => {
                        repo_root = take_val(rest, &mut i, "--repo-root", iv, "VERIFY_CHECK_FAIL")?;
                    }
                    "--receipt-path" => {
                        receipt_path =
                            take_val(rest, &mut i, "--receipt-path", iv, "VERIFY_CHECK_FAIL")?;
                    }
                    "--expected-cmd" => {
                        expected_cmd =
                            take_val(rest, &mut i, "--expected-cmd", iv, "VERIFY_CHECK_FAIL")?;
                    }
                    "--relevant-paths" => {
                        relevant_paths =
                            take_val(rest, &mut i, "--relevant-paths", iv, "VERIFY_CHECK_FAIL")?;
                    }
                    "--ignore-dirty-paths" => {
                        ignore_dirty_paths = take_val(
                            rest,
                            &mut i,
                            "--ignore-dirty-paths",
                            iv,
                            "VERIFY_CHECK_FAIL",
                        )?;
                    }
                    "--target-commit-sha" => {
                        has_target_commit_sha = true;
                        target_commit_sha =
                            take_val(rest, &mut i, "--target-commit-sha", iv, "VERIFY_CHECK_FAIL")?;
                    }
                    other => {
                        return Err(fail(
                            format!("VERIFY_CHECK_FAIL: unknown option '{other}'"),
                            1,
                        ));
                    }
                }
                i += 1;
            }
            Ok(GuardSubcommand::VerifyCheck {
                repo_root,
                receipt_path,
                expected_cmd,
                relevant_paths,
                ignore_dirty_paths,
                target_commit_sha,
                has_target_commit_sha,
            })
        }
        "check-worktree" => {
            let mut repo_root = ".".to_string();
            let mut expected_root = String::new();
            let mut expected_base_sha = String::new();
            let mut peer_roots = String::new();
            let mut require_isolated = false;
            let mut i = 0;
            while i < rest.len() {
                let (flag, iv) = parse_opt(&rest[i]);
                match flag {
                    "--repo-root" => {
                        repo_root = take_val(rest, &mut i, "--repo-root", iv, "WORKTREE_FAIL")?;
                    }
                    "--expected-root" => {
                        expected_root =
                            take_val(rest, &mut i, "--expected-root", iv, "WORKTREE_FAIL")?;
                    }
                    "--expected-base-sha" => {
                        expected_base_sha =
                            take_val(rest, &mut i, "--expected-base-sha", iv, "WORKTREE_FAIL")?;
                    }
                    "--peer-roots" => {
                        peer_roots = take_val(rest, &mut i, "--peer-roots", iv, "WORKTREE_FAIL")?;
                    }
                    "--require-isolated" if iv.is_none() => {
                        require_isolated = true;
                    }
                    other => {
                        return Err(fail(format!("WORKTREE_FAIL: unknown option '{other}'"), 1));
                    }
                }
                i += 1;
            }
            Ok(GuardSubcommand::CheckWorktree {
                repo_root,
                expected_root,
                expected_base_sha,
                peer_roots,
                require_isolated,
            })
        }
        "check-wave" => {
            let mut repo_root = ".".to_string();
            let mut wave_specs = String::new();
            let mut wave_reads = String::new();
            let mut expected_base_sha = String::new();
            let mut max_concurrency = 3i32;
            let mut partition = false;
            let mut protected_paths = String::new();
            let mut check_dirty_scope = false;
            let mut ignore_dirty_paths = String::new();
            let mut i = 0;
            while i < rest.len() {
                let (flag, iv) = parse_opt(&rest[i]);
                match flag {
                    "--repo-root" => {
                        repo_root = take_val(rest, &mut i, "--repo-root", iv, "WAVE_FAIL")?;
                    }
                    "--wave-specs" => {
                        wave_specs = take_val(rest, &mut i, "--wave-specs", iv, "WAVE_FAIL")?;
                    }
                    "--wave-reads" => {
                        wave_reads = take_val(rest, &mut i, "--wave-reads", iv, "WAVE_FAIL")?;
                    }
                    "--expected-base-sha" => {
                        expected_base_sha =
                            take_val(rest, &mut i, "--expected-base-sha", iv, "WAVE_FAIL")?;
                    }
                    "--max-concurrency" => {
                        let raw = take_val(rest, &mut i, "--max-concurrency", iv, "WAVE_FAIL")?;
                        max_concurrency = raw.trim().parse::<i32>().map_err(|_| {
                            fail("WAVE_FAIL: --max-concurrency must be between 1 and 4", 1)
                        })?;
                    }
                    "--partition" if iv.is_none() => partition = true,
                    "--protected-paths" => {
                        protected_paths =
                            take_val(rest, &mut i, "--protected-paths", iv, "WAVE_FAIL")?;
                    }
                    "--check-dirty-scope" if iv.is_none() => check_dirty_scope = true,
                    "--ignore-dirty-paths" => {
                        ignore_dirty_paths =
                            take_val(rest, &mut i, "--ignore-dirty-paths", iv, "WAVE_FAIL")?;
                    }
                    other => {
                        return Err(fail(format!("WAVE_FAIL: unknown option '{other}'"), 1));
                    }
                }
                i += 1;
            }
            Ok(GuardSubcommand::CheckWave {
                repo_root,
                wave_specs,
                wave_reads,
                expected_base_sha,
                max_concurrency,
                partition,
                protected_paths,
                check_dirty_scope,
                ignore_dirty_paths,
            })
        }
        "symbol-check" => {
            let mut repo_root = ".".to_string();
            let mut base_sha = String::new();
            let mut target_ref = String::new();
            let mut ignore_dirty_paths = String::new();
            let mut i = 0;
            while i < rest.len() {
                let (flag, iv) = parse_opt(&rest[i]);
                match flag {
                    "--repo-root" => {
                        repo_root = take_val(rest, &mut i, "--repo-root", iv, "SYMBOL_FAIL")?;
                    }
                    "--base-sha" => {
                        base_sha = take_val(rest, &mut i, "--base-sha", iv, "SYMBOL_FAIL")?;
                    }
                    "--target-ref" => {
                        target_ref = take_val(rest, &mut i, "--target-ref", iv, "SYMBOL_FAIL")?;
                    }
                    "--ignore-dirty-paths" => {
                        ignore_dirty_paths =
                            take_val(rest, &mut i, "--ignore-dirty-paths", iv, "SYMBOL_FAIL")?;
                    }
                    other => {
                        return Err(fail(format!("SYMBOL_FAIL: unknown option '{other}'"), 1));
                    }
                }
                i += 1;
            }
            Ok(GuardSubcommand::SymbolCheck {
                repo_root,
                base_sha,
                target_ref,
                ignore_dirty_paths,
            })
        }
        "diff-scope" => {
            let mut repo_root = ".".to_string();
            let mut base_sha = String::new();
            let mut prev_sha = String::new();
            let mut target_ref = String::new();
            let mut ignore_dirty_paths = String::new();
            let mut i = 0;
            while i < rest.len() {
                let (flag, iv) = parse_opt(&rest[i]);
                match flag {
                    "--repo-root" => {
                        repo_root = take_val(rest, &mut i, "--repo-root", iv, "DIFF_SCOPE_FAIL")?;
                    }
                    "--base-sha" => {
                        base_sha = take_val(rest, &mut i, "--base-sha", iv, "DIFF_SCOPE_FAIL")?;
                    }
                    "--prev-sha" => {
                        prev_sha = take_val(rest, &mut i, "--prev-sha", iv, "DIFF_SCOPE_FAIL")?;
                    }
                    "--target-ref" => {
                        target_ref = take_val(rest, &mut i, "--target-ref", iv, "DIFF_SCOPE_FAIL")?;
                    }
                    "--ignore-dirty-paths" => {
                        ignore_dirty_paths =
                            take_val(rest, &mut i, "--ignore-dirty-paths", iv, "DIFF_SCOPE_FAIL")?;
                    }
                    other => {
                        return Err(fail(
                            format!("DIFF_SCOPE_FAIL: unknown option '{other}'"),
                            1,
                        ));
                    }
                }
                i += 1;
            }
            Ok(GuardSubcommand::DiffScope {
                repo_root,
                base_sha,
                prev_sha,
                target_ref,
                ignore_dirty_paths,
            })
        }
        "mechanical-check" => {
            let mut repo_root = ".".to_string();
            let mut base_sha = String::new();
            let mut target_ref = String::new();
            let mut allowed_paths = String::new();
            let mut ignore_dirty_paths = String::new();
            let mut obsoletes = String::new();
            let mut allow_mass_delete = false;
            let mut wave_specs = String::new();
            let mut worker_changes = String::new();
            let mut worker_roots = String::new();
            let mut protected_paths = String::new();
            let mut dirty_digests = String::new();
            let mut has_dirty_digests = false;
            let mut i = 0;
            while i < rest.len() {
                let (flag, iv) = parse_opt(&rest[i]);
                match flag {
                    "--repo-root" => {
                        repo_root = take_val(rest, &mut i, "--repo-root", iv, "MECHANICAL_FAIL")?;
                    }
                    "--base-sha" => {
                        base_sha = take_val(rest, &mut i, "--base-sha", iv, "MECHANICAL_FAIL")?;
                    }
                    "--target-ref" => {
                        target_ref = take_val(rest, &mut i, "--target-ref", iv, "MECHANICAL_FAIL")?;
                    }
                    "--allowed-paths" => {
                        allowed_paths =
                            take_val(rest, &mut i, "--allowed-paths", iv, "MECHANICAL_FAIL")?;
                    }
                    "--ignore-dirty-paths" => {
                        ignore_dirty_paths =
                            take_val(rest, &mut i, "--ignore-dirty-paths", iv, "MECHANICAL_FAIL")?;
                    }
                    "--obsoletes" => {
                        obsoletes = take_val(rest, &mut i, "--obsoletes", iv, "MECHANICAL_FAIL")?;
                    }
                    "--allow-mass-delete" if iv.is_none() => allow_mass_delete = true,
                    "--wave-specs" => {
                        wave_specs = take_val(rest, &mut i, "--wave-specs", iv, "MECHANICAL_FAIL")?;
                    }
                    "--worker-changes" => {
                        worker_changes =
                            take_val(rest, &mut i, "--worker-changes", iv, "MECHANICAL_FAIL")?;
                    }
                    "--worker-roots" => {
                        worker_roots =
                            take_val(rest, &mut i, "--worker-roots", iv, "MECHANICAL_FAIL")?;
                    }
                    "--protected-paths" => {
                        protected_paths =
                            take_val(rest, &mut i, "--protected-paths", iv, "MECHANICAL_FAIL")?;
                    }
                    "--dirty-digests" => {
                        has_dirty_digests = true;
                        dirty_digests =
                            take_val(rest, &mut i, "--dirty-digests", iv, "MECHANICAL_FAIL")?;
                    }
                    other => {
                        return Err(fail(
                            format!("MECHANICAL_FAIL: unknown option '{other}'"),
                            1,
                        ));
                    }
                }
                i += 1;
            }
            Ok(GuardSubcommand::MechanicalCheck {
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
            })
        }
        "review-inventory" => {
            let mut repo_root = ".".to_string();
            let mut base_sha = String::new();
            let mut target_ref = String::new();
            let mut ignore_dirty_paths = String::new();
            let mut max_concurrency = 4i32;
            let mut i = 0;
            while i < rest.len() {
                let (flag, iv) = parse_opt(&rest[i]);
                match flag {
                    "--repo-root" => {
                        repo_root = take_val(rest, &mut i, "--repo-root", iv, "INVENTORY_FAIL")?;
                    }
                    "--base-sha" => {
                        base_sha = take_val(rest, &mut i, "--base-sha", iv, "INVENTORY_FAIL")?;
                    }
                    "--target-ref" => {
                        target_ref = take_val(rest, &mut i, "--target-ref", iv, "INVENTORY_FAIL")?;
                    }
                    "--ignore-dirty-paths" => {
                        ignore_dirty_paths =
                            take_val(rest, &mut i, "--ignore-dirty-paths", iv, "INVENTORY_FAIL")?;
                    }
                    "--max-concurrency" => {
                        let raw =
                            take_val(rest, &mut i, "--max-concurrency", iv, "INVENTORY_FAIL")?;
                        max_concurrency = raw.trim().parse::<i32>().map_err(|_| {
                            fail("INVENTORY_FAIL: --max-concurrency must be an integer", 1)
                        })?;
                    }
                    other => {
                        return Err(fail(format!("INVENTORY_FAIL: unknown option '{other}'"), 1));
                    }
                }
                i += 1;
            }
            Ok(GuardSubcommand::ReviewInventory {
                repo_root,
                base_sha,
                target_ref,
                ignore_dirty_paths,
                max_concurrency,
            })
        }
        "review-ledger" => {
            let mut repo_root = ".".to_string();
            let mut action = String::new();
            let mut ledger_path = String::new();
            let mut base_sha = String::new();
            let mut target_ref = String::new();
            let mut ignore_dirty_paths = String::new();
            let mut max_concurrency = 4i32;
            let mut max_passes: Option<i64> = None;
            let mut unit_id = String::new();
            let mut status = String::new();
            let mut findings = String::new();
            let mut specialists = String::new();
            let mut rationale = String::new();
            let mut receipt_path = String::new();
            let mut cross_unit_status = String::new();
            let mut budget_status = String::new();
            let mut review_independence = String::new();
            let mut passes_used: Option<i64> = None;
            let mut scope = String::new();
            let mut force = false;
            let mut i = 0;
            while i < rest.len() {
                let (flag, iv) = parse_opt(&rest[i]);
                match flag {
                    "--repo-root" => {
                        repo_root = take_val(rest, &mut i, "--repo-root", iv, "LEDGER_FAIL")?;
                    }
                    "--action" => {
                        action = take_val(rest, &mut i, "--action", iv, "LEDGER_FAIL")?;
                    }
                    "--ledger-path" => {
                        ledger_path = take_val(rest, &mut i, "--ledger-path", iv, "LEDGER_FAIL")?;
                    }
                    "--base-sha" => {
                        base_sha = take_val(rest, &mut i, "--base-sha", iv, "LEDGER_FAIL")?;
                    }
                    "--target-ref" => {
                        target_ref = take_val(rest, &mut i, "--target-ref", iv, "LEDGER_FAIL")?;
                    }
                    "--ignore-dirty-paths" => {
                        ignore_dirty_paths =
                            take_val(rest, &mut i, "--ignore-dirty-paths", iv, "LEDGER_FAIL")?;
                    }
                    "--max-concurrency" => {
                        let raw = take_val(rest, &mut i, "--max-concurrency", iv, "LEDGER_FAIL")?;
                        max_concurrency = raw.trim().parse::<i32>().map_err(|_| {
                            fail("LEDGER_FAIL: --max-concurrency must be an integer", 1)
                        })?;
                    }
                    "--max-passes" => {
                        let raw = take_val(rest, &mut i, "--max-passes", iv, "LEDGER_FAIL")?;
                        let v = raw.trim().parse::<i64>().map_err(|_| {
                            fail("LEDGER_FAIL: -MaxPasses must be a positive integer", 1)
                        })?;
                        max_passes = Some(v);
                    }
                    "--unit-id" => {
                        unit_id = take_val(rest, &mut i, "--unit-id", iv, "LEDGER_FAIL")?;
                    }
                    "--status" => {
                        status = take_val(rest, &mut i, "--status", iv, "LEDGER_FAIL")?;
                    }
                    "--findings" => {
                        findings = take_val(rest, &mut i, "--findings", iv, "LEDGER_FAIL")?;
                    }
                    "--specialists" => {
                        specialists = take_val(rest, &mut i, "--specialists", iv, "LEDGER_FAIL")?;
                    }
                    "--rationale" => {
                        rationale = take_val(rest, &mut i, "--rationale", iv, "LEDGER_FAIL")?;
                    }
                    "--receipt-path" => {
                        receipt_path = take_val(rest, &mut i, "--receipt-path", iv, "LEDGER_FAIL")?;
                    }
                    "--cross-unit-status" => {
                        cross_unit_status =
                            take_val(rest, &mut i, "--cross-unit-status", iv, "LEDGER_FAIL")?;
                    }
                    "--budget-status" => {
                        budget_status =
                            take_val(rest, &mut i, "--budget-status", iv, "LEDGER_FAIL")?;
                    }
                    "--review-independence" => {
                        review_independence =
                            take_val(rest, &mut i, "--review-independence", iv, "LEDGER_FAIL")?;
                    }
                    "--passes-used" => {
                        let raw = take_val(rest, &mut i, "--passes-used", iv, "LEDGER_FAIL")?;
                        let v = raw.trim().parse::<i64>().map_err(|_| {
                            fail("LEDGER_FAIL: -PassesUsed must be non-negative", 1)
                        })?;
                        passes_used = Some(v);
                    }
                    "--scope" => {
                        scope = take_val(rest, &mut i, "--scope", iv, "LEDGER_FAIL")?;
                    }
                    "--force" if iv.is_none() => force = true,
                    other => {
                        return Err(fail(format!("LEDGER_FAIL: unknown option '{other}'"), 1));
                    }
                }
                i += 1;
            }
            Ok(GuardSubcommand::ReviewLedger {
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
            })
        }
        "context-cache" => {
            let mut repo_root = ".".to_string();
            let mut action = String::new();
            let mut cache_path = String::new();
            let mut scope_id = String::new();
            let mut anchor_paths = String::new();
            let mut scope_paths = String::new();
            let mut graph_index_sha = String::new();
            let mut summary_ref = String::new();
            let mut ignore_dirty_paths = String::new();
            let mut i = 0;
            while i < rest.len() {
                let (flag, iv) = parse_opt(&rest[i]);
                match flag {
                    "--repo-root" => {
                        repo_root = take_val(rest, &mut i, "--repo-root", iv, "CONTEXT_ERROR")?;
                    }
                    "--action" => {
                        action = take_val(rest, &mut i, "--action", iv, "CONTEXT_ERROR")?;
                    }
                    "--cache-path" => {
                        cache_path = take_val(rest, &mut i, "--cache-path", iv, "CONTEXT_ERROR")?;
                    }
                    "--scope-id" => {
                        scope_id = take_val(rest, &mut i, "--scope-id", iv, "CONTEXT_ERROR")?;
                    }
                    "--anchor-paths" => {
                        anchor_paths =
                            take_val(rest, &mut i, "--anchor-paths", iv, "CONTEXT_ERROR")?;
                    }
                    "--scope-paths" => {
                        scope_paths = take_val(rest, &mut i, "--scope-paths", iv, "CONTEXT_ERROR")?;
                    }
                    "--graph-index-sha" => {
                        graph_index_sha =
                            take_val(rest, &mut i, "--graph-index-sha", iv, "CONTEXT_ERROR")?;
                    }
                    "--summary-ref" => {
                        summary_ref = take_val(rest, &mut i, "--summary-ref", iv, "CONTEXT_ERROR")?;
                    }
                    "--ignore-dirty-paths" => {
                        ignore_dirty_paths =
                            take_val(rest, &mut i, "--ignore-dirty-paths", iv, "CONTEXT_ERROR")?;
                    }
                    other => {
                        return Err(fail(format!("CONTEXT_ERROR: unknown option '{other}'"), 1));
                    }
                }
                i += 1;
            }
            Ok(GuardSubcommand::ContextCache {
                repo_root,
                action,
                cache_path,
                scope_id,
                anchor_paths,
                scope_paths,
                graph_index_sha,
                summary_ref,
                ignore_dirty_paths,
            })
        }
        "evidence-check" => {
            let mut repo_root = ".".to_string();
            let mut source_paths = String::new();
            let mut manifest_path = String::new();
            let mut write_manifest = false;
            let mut i = 0;
            while i < rest.len() {
                let (flag, iv) = parse_opt(&rest[i]);
                match flag {
                    "--repo-root" => {
                        repo_root = take_val(rest, &mut i, "--repo-root", iv, "EVIDENCE_MISSING")?;
                    }
                    "--source-paths" => {
                        source_paths =
                            take_val(rest, &mut i, "--source-paths", iv, "EVIDENCE_MISSING")?;
                    }
                    "--manifest-path" => {
                        manifest_path =
                            take_val(rest, &mut i, "--manifest-path", iv, "EVIDENCE_MISSING")?;
                    }
                    "--write-manifest" if iv.is_none() => write_manifest = true,
                    other => {
                        return Err(fail(
                            format!("EVIDENCE_MISSING: unknown option '{other}'"),
                            1,
                        ));
                    }
                }
                i += 1;
            }
            Ok(GuardSubcommand::EvidenceCheck {
                repo_root,
                source_paths,
                manifest_path,
                write_manifest,
            })
        }
        "merge-policy-check" => {
            let mut repo_root = ".".to_string();
            let mut policy_path = String::new();
            let mut pr_state: Option<String> = None;
            let mut ci_status: Option<String> = None;
            let mut review_status: Option<String> = None;
            let mut blocking_findings = 0i32;
            let mut governance_status = "CLEAR".to_string();
            let mut changed_paths = String::new();
            let mut post_merge = false;
            let mut merged_sha = String::new();
            let mut main_ref = String::new();
            let mut target_ref = String::new();
            let mut authority_ref = String::new();
            let mut base_sha = String::new();
            let mut head_sha = String::new();
            let mut ledger_path = String::new();
            let mut receipt_path = String::new();
            let mut ignore_dirty_paths = String::new();
            let mut pr_number = String::new();
            let mut repo = String::new();
            let mut target_branch = String::new();
            let mut local_only = false;
            let mut require_remote_ci = false;
            let mut i = 0;
            while i < rest.len() {
                let (flag, iv) = parse_opt(&rest[i]);
                match flag {
                    "--repo-root" => {
                        repo_root = take_val(rest, &mut i, "--repo-root", iv, "MERGE_BLOCKED")?;
                    }
                    "--policy-path" => {
                        policy_path = take_val(rest, &mut i, "--policy-path", iv, "MERGE_BLOCKED")?;
                    }
                    "--pr-state" => {
                        pr_state = Some(take_val(rest, &mut i, "--pr-state", iv, "MERGE_BLOCKED")?);
                    }
                    "--ci-status" => {
                        ci_status =
                            Some(take_val(rest, &mut i, "--ci-status", iv, "MERGE_BLOCKED")?);
                    }
                    "--review-status" => {
                        review_status = Some(take_val(
                            rest,
                            &mut i,
                            "--review-status",
                            iv,
                            "MERGE_BLOCKED",
                        )?);
                    }
                    "--blocking-findings" => {
                        let raw =
                            take_val(rest, &mut i, "--blocking-findings", iv, "MERGE_BLOCKED")?;
                        blocking_findings = raw.trim().parse::<i32>().map_err(|_| {
                            fail(format!("MERGE_BLOCKED: invalid_blocking_findings={raw}"), 1)
                        })?;
                    }
                    "--governance-status" => {
                        governance_status =
                            take_val(rest, &mut i, "--governance-status", iv, "MERGE_BLOCKED")?;
                    }
                    "--changed-paths" => {
                        changed_paths =
                            take_val(rest, &mut i, "--changed-paths", iv, "MERGE_BLOCKED")?;
                    }
                    "--post-merge" if iv.is_none() => post_merge = true,
                    "--merged-sha" => {
                        merged_sha = take_val(rest, &mut i, "--merged-sha", iv, "MERGE_BLOCKED")?;
                    }
                    "--main-ref" => {
                        main_ref = take_val(rest, &mut i, "--main-ref", iv, "MERGE_BLOCKED")?;
                    }
                    "--target-ref" => {
                        target_ref = take_val(rest, &mut i, "--target-ref", iv, "MERGE_BLOCKED")?;
                    }
                    "--authority-ref" => {
                        authority_ref =
                            take_val(rest, &mut i, "--authority-ref", iv, "MERGE_BLOCKED")?;
                    }
                    "--base-sha" => {
                        base_sha = take_val(rest, &mut i, "--base-sha", iv, "MERGE_BLOCKED")?;
                    }
                    "--head-sha" => {
                        head_sha = take_val(rest, &mut i, "--head-sha", iv, "MERGE_BLOCKED")?;
                    }
                    "--ledger-path" => {
                        ledger_path = take_val(rest, &mut i, "--ledger-path", iv, "MERGE_BLOCKED")?;
                    }
                    "--receipt-path" => {
                        receipt_path =
                            take_val(rest, &mut i, "--receipt-path", iv, "MERGE_BLOCKED")?;
                    }
                    "--ignore-dirty-paths" => {
                        ignore_dirty_paths =
                            take_val(rest, &mut i, "--ignore-dirty-paths", iv, "MERGE_BLOCKED")?;
                    }
                    "--pr-number" => {
                        pr_number = take_val(rest, &mut i, "--pr-number", iv, "MERGE_BLOCKED")?;
                    }
                    "--repo" => {
                        repo = take_val(rest, &mut i, "--repo", iv, "MERGE_BLOCKED")?;
                    }
                    "--target-branch" => {
                        target_branch =
                            take_val(rest, &mut i, "--target-branch", iv, "MERGE_BLOCKED")?;
                    }
                    "--local-only" if iv.is_none() => local_only = true,
                    "--require-remote-ci" if iv.is_none() => require_remote_ci = true,
                    other => {
                        return Err(fail(format!("MERGE_BLOCKED: unknown option '{other}'"), 1));
                    }
                }
                i += 1;
            }
            Ok(GuardSubcommand::MergePolicyCheck {
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
            })
        }
        other => Err(fail(
            format!("GUARD_FAIL: unknown guard subcommand '{other}'"),
            1,
        )),
    }
}
