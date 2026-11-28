# Scripts & Native CLI Reference

Zero-Rust bootstrapper (`bootstrap-b3.{ps1,sh}`), deterministic `b3` native CLI subcommand reference for `/b3-ship`, `/b3-research-ship`, `/b3-review-loop`, and standalone commands, and repository validation helpers (`research/decisions/decision-010-autonomous-development.md`).

> **Native engine:** All deterministic guard, PR, context-budget, sync, and install commands execute directly via the zero-dependency Rust `b3` binary (`b3 guard <subcommand>`, `b3 pr <subcommand>`, `b3 context measure --strict`, `b3 sync`, `b3 install <subcommand>`).
> **Sole zero-Rust bootstrapper:** End users only need [`bootstrap-b3.ps1`](bootstrap-b3.ps1) / [`bootstrap-b3.sh`](bootstrap-b3.sh) once to download/verify `SHA256SUMS.txt` and install `b3` atomically (with `--rollback` / `-Rollback` to `.prev`) without requiring Rust, Cargo, Node.js, Python, PowerShell, or Bash at runtime. Contributors can also build from source with `cargo build --release`.

## Retired compatibility wrappers

The `4` legacy script wrapper pairs were retired for zero wrapper overhead and a single native CLI contract (`5` adapter wrapper pairs are documented in [`../adapters/README.md`](../adapters/README.md#retired-adapter-compatibility-wrappers)):

| Retired script wrapper pair (`.ps1` + `.sh`) | Native `b3` command |
| --- | --- |
| `scripts/b3-guard.{ps1,sh}` | `b3 guard <subcommand> [flags]` |
| `scripts/b3-github-verify.{ps1,sh}` | `b3 pr verify --mode pre-merge\|post-merge --repo <owner/repo> --pr-number <N>` |
| `scripts/b3-pr-github.{ps1,sh}` | `b3 pr <fetch\|reconcile\|reply\|resolve\|comment> [flags]` |
| `scripts/measure-context.{ps1,sh}` | `b3 context measure [--repo-root <path>] [--strict]` |

## Script & native command inventory

| Entrypoint | Purpose | Usage |
| --- | --- | --- |
| [`bootstrap-b3.ps1`](bootstrap-b3.ps1) / [`bootstrap-b3.sh`](bootstrap-b3.sh) | Sole zero-Rust bootstrapper: downloads/verifies `SHA256SUMS.txt` from GitHub Releases or local `--release-dir`, runs `--version` smoke check, swaps `b3` atomically, and supports `--rollback` | `.\scripts\bootstrap-b3.ps1` / `./scripts/bootstrap-b3.sh` |
| [`ci-preflight.ps1`](ci-preflight.ps1) / [`ci-preflight.sh`](ci-preflight.sh) | Contributor local preflight helper: runs `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, `cargo build`, native `b3 context measure --strict`, and `cargo test` (`-Fast`/`--fast` runs `--lib --test eval_contracts`) | `.\scripts\ci-preflight.ps1` / `./scripts/ci-preflight.sh` |
| `b3 guard <subcommand>` | Provider-neutral deterministic helpers across all `14` B3 commands (`/b3-ship`, `/b3-research-ship`, `/b3-review`, `/b3-audit`, `/b3-review-loop`, `/b3-verify`, `/b3-plan`, `/b3-implement`, `/b3-debug`, `/b3-research`, `/b3-refactor`, and `/b3-pr-{resolve,reply,comment}`) | `b3 guard <subcommand> [flags]` |
| `b3 pr verify` | Read-only GitHub verification (`src/pr/verify.rs`), invoked by `b3 guard merge-policy-check` when `--pr-number <N>` is supplied (PR identity/state/mergeability, target & `default_branch` policy authority SHAs, head-SHA-bound CI checks/statuses, changed files, and post-merge compare; emits `GH_VERIFY_UNAVAILABLE` exit `2` when `gh`/auth/network/binary is unavailable) | `b3 pr verify --mode pre-merge\|post-merge --repo <owner/repo> --pr-number <N>` |
| `b3 pr <cmd>` | GitHub PR feedback lifecycle (`src/pr/github.rs` + `src/pr/gh_exec.rs`: `fetch`, `reconcile`, `reply`, `resolve`, `comment`) reusing canonical `b3 guard verify-check`, `<git-common-dir>/b3/pr-feedback/` state & PID-safe locking, strict diff-hunk validation, stdin-JSON `gh api`, untrusted framing, separate auth gates, and remote object verification | `b3 pr <cmd> [flags]` |
| `b3 context measure` | Measure always-on (`AGENTS.md`, `rules/*.md`, `38` `SKILL.md` frontmatters across `24` canonical `skills/` + `14` `adapters/command-skills/`), `/b3-ship`, `/b3-research-ship`, `/b3-review-loop`, `context_routing`, standalone command loads (`standalone_cmds`), subagent review delta, and role static context bytes/tokens (`--strict` exits `1` on cap violation) | `b3 context measure --strict` |
| [`../tests/`](../tests/) | Native cross-platform Rust test suites (`eval_contracts`, `guard_security_and_behavior`, `merge_policy_security`, `pr_feedback_lifecycle`, `adapters_and_hosts`, `native_core_behaviors`, `native_golden_parity`, `bootstrap_lifecycle`) covering CLI contracts, merge/PR/filesystem security, installers, 355 eval fixtures, and bootstrap upgrades | `cargo test` |

## `b3 guard` subcommands (`src/cli.rs`)

`b3 --help` prints the command list; per-subcommand syntax and flags live in [`../src/cli.rs`](../src/cli.rs) (note: `b3 guard --help` is not a standalone help entrypoint).

| Subcommand | Exit codes | Key flags & contract |
| --- | --- | --- |
| `fingerprint` | `0` ok, `1` error | `--depends-on`, `--scope`, `--criteria` → canonical `depends_on=\|scope=\|acceptance_criteria=` |
| `check-freshness` | `0` `FRESH`, `2` `STALE`, `1` error | `--approach-at-sha`, `--task-base-sha`, `--watched-paths` (`--owned-files`, `--ignore-dirty-paths`) |
| `precommit` | `0` `PRECOMMIT_OK`, `1` fail | `--allowed-paths`, `--require-verify-receipt`, `--expected-cmd`, `--relevant-paths`; checks staging, `staged == WT`, receipt provenance/scope/manifests |
| `snapshot` | `0` SHA, `1` error | Creates detached snapshot excluding `.b3/{ship,research-ship}` and failing on sensitive paths/dirty submodules |
| `diff-scope` | `0` summary/`CLEAN_AFTER_FIX`, `2` `EMPTY_DIFF`, `1` error | `--base-sha`, `--prev-sha`, `--target-ref`, `--ignore-dirty-paths`; T-shirt size (`XS`..`XXL`, `NOISE_ONLY`) + decoupled risk |
| `review-inventory` | `0` summary, `2` `EMPTY_DIFF`/`PARTITION_INCOMPLETE`, `1` error | `--base-sha`, `--target-ref`, `--max-concurrency`; L0 cohesive `unit\|U0N\|...`, `l1_specialists`, adaptive concurrency |
| `review-ledger` | `0` ok/`LEDGER_GATE_PASS`, `2` incomplete/stale/blocked, `1` bad args/corrupt | `--action init\|update\|normalize\|check`, `--ledger-path`, `--max-passes`, `--passes-used`, `--review-independence`, `--unit-id`, `--status`, `--receipt-path` |
| `mechanical-check` | `0` `MECHANICAL_OK`/`MECHANICAL_ADVISORY`, `2` findings/violations, `1` error | `--allowed-paths`, `--wave-specs`, `--worker-changes`/`--worker-roots`, `--worker-bases`, `--protected-paths`, `--dirty-digests`, `--obsoletes` |
| `symbol-check` | `0` `SYMBOL_OK`/`SYMBOL_ADVISORY`, `2` `SYMBOL_FINDINGS`, `1` error | `--base-sha`, `--target-ref`; blocks on `dangling_refs`, surfaces `orphan_internal` as `SYMBOL_ADVISORY` |
| `verify-run` / `verify-check` | `verify-run`: `0` `VERIFY_PASS`, `1` fail; `verify-check`: `0` `VERIFY_VALID`, `2` `VERIFY_STALE`, `1` mismatch/corrupt | `--receipt-path`, `--verify-cmd` / `--expected-cmd`, `--relevant-paths`, `--log-path`, `--target-commit-sha` |
| `check-wave` | `0` `WAVE_OK`/`WAVE_PARTITIONED`/`WAVE_SEQUENTIAL`, `2` conflict/base, `1` error | `--wave-specs`, `--wave-reads`, `--active-specs`, `--active-reads`, `--verified-dirty-paths`, `--protected-paths`, `--expected-base-sha`, `--check-dirty-scope`, `--partition`, `--max-concurrency` |
| `check-worktree` | `0` `WORKTREE_OK`, `2` `WORKTREE_UNSAFE`, `1` error | `--expected-root`, `--require-isolated`, `--peer-roots`, `--expected-base-sha` |
| `new-run` / `resolve-run` / `list-runs` / `prune` | `0` ok (`resolve-run`: `1` `NO_ACTIVE_RUN`) | `--namespace ship\|research-ship`, `--slug` / `--run-id`, `--keep` (`prune` default `10`) |
| `evidence-check` | `0` `EVIDENCE_FRESH`/`WRITTEN`, `2` `EVIDENCE_STALE`, `1` invalid | `--write-manifest`, `--manifest-path`, SHA-256 `b3-evidence-v1` containment checks |
| `merge-policy-check` | `0` `MERGE_AUTHORIZED`/`POST_MERGE_VERIFIED`, `2` `PR_READY`/`LOCAL_ELIGIBLE_ONLY`/`PROVIDER_UNAVAILABLE`, `1` blocked/failed | `--pr-number`, `--receipt-path`, `--main-ref`, `--authority-ref`, `--post-merge`, `--local-only`, `--require-remote-ci` |
| `context-cache` | `0` `CONTEXT_RECORDED`/`CONTEXT_FRESH`, `2` `CONTEXT_STALE`, `1` error/corrupt/mismatch | `--action record\|check`, `--cache-path`, `--anchor-paths`, `--scope-paths`, `--summary-ref`, `--graph-index-sha` |

### Merge Authorization Trust Boundary & Migration

- **Provider-neutral B3 Core + optional GitHub adapter:** `b3 guard merge-policy-check` operates cleanly in local Git repositories, non-GitHub remotes, and environments without `gh`. Policy is always read from canonical trunk authority (`<authority_ref>:.b3/policy.toml` or legacy `<authority_ref>:.b3/research-policy.json` on `origin/HEAD` / `main` / `--authority-ref`, migratable via `b3 config migrate`), blocking unmerged branches or dirty worktrees from self-authorizing `auto_merge: authorized` or relaxing `protected_paths`. On remote-backed repositories without live provider verification, `ls-remote` checks remote authority/target freshness (`stale_remote_ref` → `MERGE_BLOCKED`) and emits `LOCAL_ELIGIBLE_ONLY` (exit `2`, non-authorizing for remote merge) rather than granting remote `MERGE_AUTHORIZED`. When `--pr-number <N>` is passed, `b3 guard` delegates GitHub-specific PR/CI/target metadata queries to `b3 pr verify` (`b3-gh-verify-v2`) and degrades honestly to `PROVIDER_UNAVAILABLE` (exit `2`, never `PASS`) when `gh`, credentials, or GitHub APIs are unreachable.
- **Native hosting enforcement & CI evidence boundary:** GitHub-specific branch protection, ruleset evaluation, repository permission tiers, and reviewer association rules are enforced natively by the hosting provider on merge rather than simulated inside `b3 guard`. Locally, `MERGE_AUTHORIZED` (`mode=local|github`) requires `auto_merge: authorized` in trunk policy plus a fresh `LEDGER_GATE_PASS` `b3-review-ledger-v1` bound to exact `base_sha`/`head_sha` with `review_independence=INDEPENDENT`; when `require_ci: true`, caller `--ci-status PASS` can block if negative (`FAIL`/`PENDING`) but never authorizes without an exact-commit `b3-verify-v1` `--receipt-path` (or receipt-backed ledger units) or independently observed provider CI (and `--require-remote-ci` forbids silently downgrading to local receipts).
- **Review-ledger migration (`review_independence`):** `review-ledger --action init` defaults to `review_independence=UNKNOWN` (failing closed on `HIGH`/`CRITICAL` and `merge-policy-check`). Pre-existing `b3-review-ledger-v1` files missing `review_independence=` fail closed as `LEDGER_CORRUPT` on `check` and migrate deterministically to `review_independence=UNKNOWN` via `b3 guard review-ledger --action normalize --ledger-path <path>`.

### Receipt migration (`b3-verify-v1`)

Legacy `b3-verify-v1` receipts generated before mode/type/gitlink fingerprinting retain the same schema and header fields, fail closed with `VERIFY_STALE` (exit `2` on `verify-check`, exit `1` `PRECOMMIT_FAIL` wrapping `VERIFY_STALE` on `precommit --require-verify-receipt`), and auto-migrate cleanly when re-verified via `verify-run` (no manual receipt deletion or schema migration step required). Staged-vs-working-tree blob synchronization continues to be enforced by `precommit` while `verify-check` verifies effective working state plus index presence/mode divergence.
