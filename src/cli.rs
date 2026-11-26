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
  new-run           Create a timestamped run directory and update CURRENT
  resolve-run       Resolve active or named run path
  list-runs         List runs for a namespace
  prune             Prune older PASS runs keeping the newest N"
}

fn take_val(
    args: &[String],
    idx: &mut usize,
    opt: &str,
    err_prefix: &str,
) -> Result<String, B3Error> {
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
        match args[i].as_str() {
            "--repo-root" => repo_root = take_val(args, &mut i, "--repo-root", "CONTEXT_FAIL")?,
            "--strict" => strict = true,
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
                match rest[i].as_str() {
                    "--depends-on" => {
                        depends_on = take_val(rest, &mut i, "--depends-on", "FINGERPRINT_FAIL")?;
                    }
                    "--scope" => {
                        scope = take_val(rest, &mut i, "--scope", "FINGERPRINT_FAIL")?;
                    }
                    "--criteria" | "--criterion" => {
                        let opt = rest[i].as_str();
                        criteria.push(take_val(rest, &mut i, opt, "FINGERPRINT_FAIL")?);
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
                match rest[i].as_str() {
                    "--repo-root" => {
                        repo_root = take_val(rest, &mut i, "--repo-root", "FRESHNESS_FAIL")?;
                    }
                    "--approach-at-sha" => {
                        approach_at_sha =
                            take_val(rest, &mut i, "--approach-at-sha", "FRESHNESS_FAIL")?;
                    }
                    "--task-base-sha" => {
                        task_base_sha =
                            take_val(rest, &mut i, "--task-base-sha", "FRESHNESS_FAIL")?;
                    }
                    "--watched-paths" => {
                        watched_paths =
                            take_val(rest, &mut i, "--watched-paths", "FRESHNESS_FAIL")?;
                    }
                    "--owned-files" => {
                        owned_files = take_val(rest, &mut i, "--owned-files", "FRESHNESS_FAIL")?;
                    }
                    "--ignore-dirty-paths" => {
                        ignore_dirty_paths =
                            take_val(rest, &mut i, "--ignore-dirty-paths", "FRESHNESS_FAIL")?;
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
                match rest[i].as_str() {
                    "--repo-root" => {
                        repo_root = take_val(rest, &mut i, "--repo-root", "SNAPSHOT_FAIL")?;
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
                match rest[i].as_str() {
                    "--repo-root" => {
                        repo_root = take_val(rest, &mut i, "--repo-root", "NEW_RUN_FAIL")?;
                    }
                    "--slug" => {
                        slug = take_val(rest, &mut i, "--slug", "NEW_RUN_FAIL")?;
                    }
                    "--timestamp" => {
                        timestamp = take_val(rest, &mut i, "--timestamp", "NEW_RUN_FAIL")?;
                    }
                    "--namespace" => {
                        namespace = take_val(rest, &mut i, "--namespace", "NEW_RUN_FAIL")?;
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
                match rest[i].as_str() {
                    "--repo-root" => {
                        repo_root = take_val(rest, &mut i, "--repo-root", "RESOLVE_FAIL")?;
                    }
                    "--run-id" => {
                        run_id = take_val(rest, &mut i, "--run-id", "RESOLVE_FAIL")?;
                    }
                    "--namespace" => {
                        namespace = take_val(rest, &mut i, "--namespace", "RESOLVE_FAIL")?;
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
                match rest[i].as_str() {
                    "--repo-root" => {
                        repo_root = take_val(rest, &mut i, "--repo-root", "LIST_FAIL")?;
                    }
                    "--namespace" => {
                        namespace = take_val(rest, &mut i, "--namespace", "LIST_FAIL")?;
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
                match rest[i].as_str() {
                    "--repo-root" => {
                        repo_root = take_val(rest, &mut i, "--repo-root", "PRUNE_FAIL")?;
                    }
                    "--keep" => {
                        let raw = take_val(rest, &mut i, "--keep", "PRUNE_FAIL")?;
                        keep = raw
                            .trim()
                            .parse::<i32>()
                            .map_err(|_| fail("PRUNE_FAIL: --keep must be an integer >= 0", 1))?;
                    }
                    "--namespace" => {
                        namespace = take_val(rest, &mut i, "--namespace", "PRUNE_FAIL")?;
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
        other => Err(fail(
            format!("GUARD_FAIL: unknown guard subcommand '{other}'"),
            1,
        )),
    }
}
