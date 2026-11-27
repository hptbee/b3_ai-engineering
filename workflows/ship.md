# Ship lifecycle

Verified end-to-end delivery until done or blocked.

```text
Preflight → Plan → continuous Scope/Build/Verify/Review/Commit → Finalize
```

Links: [feature-impl](feature-implementation.md), [review-loop](../review-loop/strategy.md), [templates](references/ship-templates.md), [resume](references/ship-resume.md), [dispatch](references/dispatch-naming.md), [context-routing](references/context-routing.md), `b3 guard`.

## Context, hosts & B3 roots

- **Use:** full run, `resume [<run_id>]`, or `status [<run_id>|--all]` (not 1-step cmds); overrides `planning`/`problem-solving` stops (`precedence.md`).
- **Hosts:** Cursor/Claude (`/b3-ship`), Codex (`$b3-ship`), Antigravity (`b3-ship`); re-invoke to resume.
- **Roots:** `PRODUCT_ROOT` = git root; `B3_HOME` = 1st dir (`B3_HOME` env → `.b3/home` → host global → repo) w/ `workflows/ship.md` (else `BLOCKED`). Load skills/rules/agents from `B3_HOME`, state/commits in `PRODUCT_ROOT`, never copy `skills/`.

## State & git policy

In `{PRODUCT_ROOT}/.b3/ship/`: `CURRENT` (`<run_id>`) + `runs/<run_id>/` (`{RUN_DIR}` via `resolve-run`: `master-plan.md`, `progress.md`, `findings.md`, `approach/T00N.md`, `logs/`).
- **Hygiene:** read `CURRENT` → `{RUN_DIR}/`; scan `runs/` only on `status --all` (`list-runs`) or `prune` (keeps 10 `PASS` + `CURRENT`/non-`PASS`).
1. Products ignore `.b3/ship/` (track `.b3/home`); B3 ignores `.b3/`.
2. Never `git add .b3/ship/`, `-A`, or `.`; run `b3 guard precommit` pre-commit.
3. Ignored `.b3/` never dirties tree; unignored run files block `PASS`.
4. **Thin Parent:** post-commit, collapse `progress.md` `## Approach` to 1L; read summaries/diffs/contracts; write red/`>35L` logs to `{RUN_DIR}/logs/`.

## Input & Preflight

1. `status [<run_id>|--all]` → `b3 guard list-runs`/`resolve-run` + Git report (0 edits).
2. `resume [<run_id>]`, or bare `/b3-ship` when `run_status != PASS` → **Scenario C** ([resume](references/ship-resume.md); update `CURRENT`).
3. Empty request + no checkpoint → ask user (`BLOCKED`).
4. Input → `b3 guard new-run` (`CURRENT`), then **Scenario B** (plan) or **A** (`debugging`/`refactoring`).

### Scenario A/B (Preflight & Plan)

1. Restate request + current/desired behavior (`reuse:`).
2. **Preflight:** record `initial_dirty_paths` + CI/manifest `build`/`typecheck`/`lint`/`test`; run `run_base_sha` baseline only on `Verify` failure (`baseline_status`: `PASS`|`FAIL(...)`|`NOT_RUN(verify_green)`).
3. **Plan:** `{RUN_DIR}/master-plan.md` ([templates](references/ship-templates.md), `planning` + `simplest-correct`): 3–5 `Invariants`, `AC1..ACn`, contracts, `T001` hotspots, split if `>~800L`/`>=2` areas. Scenario B keeps intent, marks `completed` via Git proof only, copies plan 1x.
4. Execute directly; `BLOCKED` only on ambiguity, `initial_dirty_paths` overlap, external ops (push/merge/deploy/reset/secrets/prod), or unasked breaking changes; `detailed` triggers on risk only (§Scope.2, never task count).

## Execution

Init `progress.md` ([templates](references/ship-templates.md); Git-reconstruct `run_base_sha`, else `INCOMPLETE`). Evaluate ready tasks (`pending` + `depends_on` verified & output-ready: `output_ready` in shared WT, `integrated` in Parent on `ISOLATED_WRITES`, [dispatch](references/dispatch-naming.md)) continuously; `task_base` = `HEAD`, run **Scope**.

### Scope (Just-in-Time planning + Gate)

Skip `planning`; follow `skills/engineering/problem-solving/SKILL.md`:
1. Inspect targets, callers, contracts, schema, tests (`context-routing.md`/`context-cache` on demand); split **`files`** vs **`read_only_deps`** (`watched_paths` = both); set **`reuse:`**, **`obsoletes:`** (`none`).
2. **Depth:** `inline` (`progress.md`), `notes` (`approach/T00N.md`), `detailed` (risk-only: API/contract/schema/auth/migration/concurrency/data-integrity/prod/new layer; `failure_matrix:`, `write_paths:` `>=2` stores + invalidation, `io_budget:` loops).
3. **Refinement:** >1 commit → narrow task, add `T00N` slices, chain `depends_on`, retarget dependents, bump `version`/`plan_id`/`plan_version`, log `Plan changes`, re-Scope.
4. **Readiness Gate:** `readiness: draft` → `ready` only when `inspected`, `files` (or new-file), `watched_paths`, `reuse`, `obsoletes`, `changes`, `verification` are set + `b3 guard fingerprint` (`task_spec_fingerprint` + `approach_at_sha` = `HEAD`) on multi-task, resume/handoff, or `notes`/`detailed` (optional on 1-task 1-turn `inline`; else `INCOMPLETE`).
5. **Pre-code Review (`detailed`):** concurrent `SHARED_READ_ONLY` contrarian `b3-{architecture,security}-reviewer.md` (`design-only`, `dispatch-naming.md`) on auth/untrusted input/race/abuse; on `CONFIRMED` flaw, revise (`readiness: draft`) and re-run Readiness Gate.

### Build (Continuous Waves & Modes) & Verify

- **Build:** dispatch per [dispatch](references/dispatch-naming.md) + `.b3/models.md` (1-task `XS`+`inline` inline if `implementation` unset/`auto`/matches `main`, else `b3-impl-t00N`; 0 nested subagents). With `>=2` ready tasks or active workers, run `b3 guard check-wave --partition` (`--wave-specs`, `--wave-reads`, `--active-specs`, `--active-reads`, `--verified-dirty-paths`, `--protected-paths`, `--ignore-dirty-paths`, `--check-dirty-scope`, `--expected-base-sha`): act on `admitted_tasks` (`wave|1|`, bounded by `available_slots`), queue `deferred_tasks`, across `SHARED_READ_ONLY`, `SHARED_DISJOINT_WRITES`, `ISOLATED_WRITES` (`b3 guard check-worktree --require-isolated`), or `SEQUENTIAL` (malformed → `malformed_wave_output`/`BLOCKED`; never claim `PARALLEL` if sequential; 1-task/0-active keeps guards). Re-evaluate ready tasks on each worker exit (no wave barrier). Save `impl_agent`, `mode`, `worker_root`, `integration`, `last_wave:`; pass `<=25L` `Context Packet` (`approach/T00N.md`/`### T00N` minus `## Inspected`, `files`/`read_only_deps`, 1L `context_hint:`, skill; no `ship.md`/`master-plan.md`).
- **Verify:** minimal edits (`problem-solving` + domain skill), delete `obsoletes`. Run `b3 guard verify-run` (`{RUN_DIR}/evidence/T00N.verify`, `--relevant-paths` on waves, red/`>35L` → `{RUN_DIR}/logs/`; no pipe masking); skip immediate `verify-check` after `verify-run` `0` w/ 0 edits (`verify-check` for resume/unchanged); fix own reds or check `run_base_sha` baseline.

### Review (Guard → Reviewer → Fix) & Commit

1. **Guard (0 tok, pre-review):** `b3 guard diff-scope` (`--base-sha {task_base}`; fallback `git diff --name-only`/`--cached`/untracked) + `b3 guard mechanical-check` (`--base-sha`, `--allowed-paths`, `--wave-specs` + `--worker-changes` or `--worker-roots`/`--worker-bases` when Parent `HEAD` advanced while peer WTs ran, `--protected-paths`, `--dirty-digests`, `--obsoletes`, [dispatch](references/dispatch-naming.md)) + `b3 guard symbol-check` on refactors (never `HEAD~1`) → `strategy.md` Iter 1. Fix/block `exit 2` (`MECHANICAL_FINDINGS`/`SYMBOL_FINDINGS` `dangling_refs`; `safety_hits` → `BLOCKED`; proven FP noted; no proof from `UNVERIFIED_COMBINED_ONLY`). Pass `exit 0` `MECHANICAL_ADVISORY` (`advisory_hits=`: `@ts-ignore`, `eslint-disable`, `empty-todo`)/`SYMBOL_ADVISORY` (`orphan_internal`) + compiler/lint output to Reviewer.
2. **Reviewer & Fix:** 1L `context_hint:` (`context-routing.md`): `inline`+`XS`/`S`+`LOW` → 1 fresh `b3-reviewer.md` (escalate blocker); else [`../review-loop/strategy.md`](../review-loop/strategy.md) (`L`/`XL`/`XXL` + `hierarchical.md`; skips Iter-1 guards if unchanged; pre-Fix `b3 guard snapshot`). `SINGLE_AGENT_LIMIT` blocks `PASS` on `HIGH`/`CRITICAL` (`INCOMPLETE`, no `auto_merge`).
3. **Commit:** single-writer commits need ACs, 0 blockers, in-scope diff, 0 residue, + `b3 guard precommit --require-verify-receipt {RUN_DIR}/evidence/T00N.verify --expected-cmd <task-cmd> --relevant-paths <files+deps>` (cmd + `files` + `read_only_deps`/configs; `verify-check` for resume/Finalize/review/PR-resolve). **Never `git commit` (`HEAD` advance) in a shared WT while peer `SHARED_DISJOINT_WRITES` workers are active** — set `integration=output_ready`, pass verified files via `--verified-dirty-paths` to unblock dependents immediately, and commit in a quiescent window; in `ISOLATED_WRITES`, integrate into Parent (`integration=integrated`) before starting dependents without rebasing/mutating active peer WTs. Commit 1x (no `--no-verify`/amend/reset/push/merge/deploy), record SHA + `completed`, collapse `T00N`, recompute deps (`check-freshness`/dirty scope); parallel code waves add post-integration `verify-run` + cross-unit review.

## Finalize & Outcomes

All required tasks `completed`:
1. Verify `AC1..ACn` e2e, `Invariants`, full checks vs `baseline_status` (`verify-check` if unchanged; `PASS` → `NOT_RUN(verify_green)`), `git log --oneline {run_base_sha}..HEAD`.
2. Cumulative `review-loop` on `{run_base_sha}..HEAD` (excl. `initial_dirty_paths`): **only** on `>=2` completed tasks/post-task edits; if task receipts `FRESH`, cap to **Cross-Cutting** (`git diff --stat`, contracts, duplication, residue) + post-task deltas (full diff if stale/missing); fixes need `verify-run` + `precommit --require-verify-receipt --expected-cmd <cmd> --relevant-paths <csv>` → 1 `final` commit.
3. Unignored run-dirty files block `PASS` (`INCOMPLETE`). Set `run_status` (`PASS`|`FAIL`|`INCOMPLETE`|`BLOCKED`); report `last_wave:`, ACs, SHAs, checks, review, unverified claims, `{RUN_DIR}/pr-body.md` ([pr-template.md](references/pr-template.md)); PR feedback: `pr-feedback/SKILL.md`.
