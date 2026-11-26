use crate::error::{fail, B3Error};

#[derive(Debug, Clone, PartialEq, Eq)]
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
        other => Err(fail(
            format!("GUARD_FAIL: unknown guard subcommand '{other}'"),
            1,
        )),
    }
}
