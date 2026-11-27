# Ship lifecycle

Verified end-to-end delivery until done or blocked.

```text
Preflight → Plan → continuous Scope/Build/Verify/Review/Commit → Finalize
```

Links: [feature-impl](feature-implementation.md), [review-loop](../review-loop/strategy.md), [templates](references/ship-templates.md), [resume](references/ship-resume.md), [dispatch](references/dispatch-naming.md), [context-routing](references/context-routing.md), `b3 guard`.

## Context, hosts & B3 roots

- **Use:** full run, `resume [<run_id>]`, or `status [<run_id>|--all]` (not 1-step commands); overrides `planning`/`problem-solving` stops (`precedence.md`).
- **Hosts:** Cursor/Claude (`/b3-ship`), Codex (`$b3-ship`), Antigravity (`b3-ship`); resume by re-invoking.
- **Roots:** `PRODUCT_ROOT` = git root; `B3_HOME` = first dir (`B3_HOME` env → `.b3/home` → host global → repo) with `workflows/ship.md` (else `BLOCKED`). Load skills/rules/agents from `B3_HOME`, state/commits in `PRODUCT_ROOT`, never copy `skills/`.

## State & git policy

In `{PRODUCT_ROOT}/.b3/ship/`: `CURRENT` (`<run_id>`) + `runs/<run_id>/` (`{RUN_DIR}` via `resolve-run`: `master-plan.md`, `progress.md`, `findings.md`, `approach/T00N.md`, `logs/`).
- **Hygiene:** read `CURRENT` → `{RUN_DIR}/`; scan `runs/` only on `status --all` (`list-runs`) or `prune` (keeps 10 `PASS` + `CURRENT`/non-`PASS`).
1. Product repos ignore `.b3/ship/` (track `.b3/home`); B3 repo ignores `.b3/`.
2. Never `git add .b3/ship/`, `git add -A`, or `git add .`; run `b3 guard precommit` before every commit.
3. Ignored `.b3/` never dirties the tree; unignored run files block `PASS`.
4. **Thin Parent:** post-commit, collapse `progress.md` `## Approach` to 1L; read summaries/diffs/contracts; write red logs `>35L` to `{RUN_DIR}/logs/`.

## Input & Preflight

1. `status [<run_id>|--all]` → `b3 guard list-runs`/`resolve-run` + Git report (0 edits).
2. `resume [<run_id>]`, or bare `/b3-ship` when `run_status != PASS` → **Scenario C** ([resume](references/ship-resume.md); update `CURRENT`).
3. Empty request and no checkpoint → ask user (`BLOCKED`).
4. Input → `b3 guard new-run` (`CURRENT`), then **Scenario B** (plan) or **A** (`debugging`/`refactoring`).

### Scenario A/B (Preflight & Plan)

1. Restate request, current/desired behavior (`reuse:`).
2. **Preflight:** record `initial_dirty_paths` + `build`/`typecheck`/`lint`/`test` from CI/manifests; run baseline at `run_base_sha` only on `Verify` failure (`baseline_status`: `PASS`|`FAIL(...)`|`NOT_RUN(verify_green)`).
3. **Plan:** write `{RUN_DIR}/master-plan.md` ([templates](references/ship-templates.md), `planning` + `simplest-correct`): 3–5 `Invariants`, `AC1..ACn`, contracts, hotspots in `T001`, split if `>~800L`/`>=2` areas. Scenario B keeps intent, marks `completed` via Git proof only, copies plan once.
4. Execute directly. `BLOCKED` only on ambiguity, `initial_dirty_paths` overlap, external ops (push/merge/deploy/reset/secrets/prod), or unasked breaking changes; `detailed` triggers on risk only (§Scope.2, not task count).

## Execution

Record `run_id`, `b3_home`, `product_root`, `plan_id`, `plan_version`, `branch`, `run_base_sha`, `baseline_status`, `initial_dirty_paths`, `last_wave:` in `progress.md` (Git-reconstruct `run_base_sha`, else `INCOMPLETE`). Evaluate ready tasks (`pending`, `depends_on` done) continuously per [dispatch](references/dispatch-naming.md); `task_base` = `git rev-parse HEAD`, run **Scope**.

### Scope (Just-in-Time planning + Gate)

Skip `planning`; follow `skills/engineering/problem-solving/SKILL.md`:
1. Inspect targets, callers, contracts, schema, tests (`context-routing.md`/`context-cache` on demand); split **`files`** vs **`read_only_deps`** (`watched_paths` = `files` + `read_only_deps`); set **`reuse:`**, **`obsoletes:`** (`none`).
2. **Depth:** `inline` (`progress.md`), `notes` (`approach/T00N.md`), `detailed` (risk-only: API/contract/schema/auth/migration/concurrency/data-integrity/prod/new layer; `failure_matrix:`, `write_paths:` `>=2` stores + invalidation, `io_budget:` loops).
3. **Evidence-based refinement:** >1 commit → narrow task, add `T00N` slices, chain `depends_on`, retarget dependents, bump `version`/`plan_id`/`plan_version`, log `Plan changes`, re-Scope.
4. **Implementation Readiness Gate:** start `readiness: draft`; set `readiness: ready` only when `inspected`, `files` (or new-file), `watched_paths`, `reuse`, `obsoletes`, `changes`, `verification` are filled, plus `b3 guard fingerprint` (`task_spec_fingerprint` + `approach_at_sha` = `git rev-parse HEAD`) on multi-task, resume/handoff, or `notes`/`detailed` tasks (optional on 1-task single-turn `inline`; else `INCOMPLETE`).
5. **Pre-code Review (`detailed`):** run contrarian `b3-architecture-reviewer.md` (`design-only`) + `b3-security-reviewer.md` (`design-only`) concurrently in `SHARED_READ_ONLY` (`dispatch-naming.md`) on auth/untrusted input/race/abuse. On `CONFIRMED` flaw, revise, set `readiness: draft`, and **re-run the Implementation Readiness Gate** pre-`Build`.

### Build (Continuous Waves & Modes) & Verify

- **Build:** dispatch per ready task ([dispatch](references/dispatch-naming.md), `.b3/models.md`): 1-task `XS`+`inline` runs inline if `implementation` is unset/`auto` or matches `main`, else `b3-impl-t00N` (no nested subagents). With `>=2` ready tasks, run `b3 guard check-wave --partition` (`--wave-reads`, `--protected-paths`, `--ignore-dirty-paths`, `--check-dirty-scope`, `--expected-base-sha`) for `wave|N|...` across `SHARED_READ_ONLY`, `SHARED_DISJOINT_WRITES`, `ISOLATED_WRITES` (`b3 guard check-worktree --require-isolated`), or `SEQUENTIAL` (malformed → `malformed_wave_output`/`BLOCKED`; never claim `PARALLEL` when sequential); 1-task/sequential chains run sequentially keeping scope/dirty/commit guards. Release unblocked dependents once verified. Save `impl_agent`, `mode`, `worker_root`, `last_wave:`; pass `Context Packet` (`approach/T00N.md` or `progress.md` `### T00N`, minus `## Inspected`, `files`/`read_only_deps`, 1L `context_hint:`, skill; never `ship.md`/`master-plan.md`; `<=25L`).
- **Verify:** minimal edits (`problem-solving` + domain skill), delete `obsoletes`. Run `b3 guard verify-run` (`{RUN_DIR}/evidence/T00N.verify`, `--relevant-paths` on waves, red/`>35L` logs → `{RUN_DIR}/logs/`; no pipe masking); skip immediate `verify-check` after `verify-run` exit `0` with 0 edits (`verify-check` is for resume/unchanged state); fix own reds or check `run_base_sha` baseline.

### Review (Guard → Reviewer → Fix) & Commit

1. **Guard (0 tok, once pre-review):** `ship.md` runs `b3 guard diff-scope` (`--base-sha {task_base}`; fallback `git diff --name-only`/`--cached`/untracked) + `b3 guard mechanical-check` (`--base-sha`, `--allowed-paths`, `--wave-specs` + `--worker-changes`/`--worker-roots`, `--protected-paths`, `--dirty-digests`, `--obsoletes`, [dispatch](references/dispatch-naming.md)) + `b3 guard symbol-check` on refactors (never `HEAD~1`) → `strategy.md` Iter 1. Fix/block `exit 2` (`MECHANICAL_FINDINGS`/`SYMBOL_FINDINGS` `dangling_refs`; `safety_hits` → `BLOCKED`; proven textual FP noted; never claim proof from `UNVERIFIED_COMBINED_ONLY`). Surface `exit 0` `MECHANICAL_ADVISORY` (`advisory_hits=`: `@ts-ignore`, `eslint-disable`, `empty-todo`)/`SYMBOL_ADVISORY` (`orphan_internal`) to Reviewer w/ compiler/linter output (non-blocking).
2. **Reviewer & Fix:** 1L `context_hint:` (`context-routing.md`): `inline`+`XS`/`S`+`LOW` → 1 fresh `b3-reviewer.md` pass (escalate blocker); else [`../review-loop/strategy.md`](../review-loop/strategy.md) (`L`/`XL`/`XXL` + `hierarchical.md`; skips Iter-1 guards if unchanged; pre-Fix `b3 guard snapshot`). `SINGLE_AGENT_LIMIT` blocks `PASS` on `HIGH`/`CRITICAL` (`INCOMPLETE`, no `auto_merge`).
3. **Commit:** single-writer commits require ACs, 0 blockers, in-scope diff, 0 residue, and `b3 guard precommit --require-verify-receipt {RUN_DIR}/evidence/T00N.verify --expected-cmd <task-cmd> --relevant-paths <files+deps>` (must pass task command + `files` + relevant `read_only_deps`/configs when validating/reusing receipts; `verify-check` is for resume/Finalize/review/PR-resolve). Commit 1x (no `--no-verify`/amend/reset/push/merge/deploy), record SHA + `completed`, collapse `T00N`. Post-wave: recompute deps, `check-freshness`/dirty scope, re-enter `Build` (`check-wave --partition` if `>=2` ready); parallel code waves add post-integration `verify-run` + cross-unit review.

## Finalize & Outcomes

All required tasks `completed`:
1. Verify `AC1..ACn` e2e, `Invariants`, full checks vs `baseline_status` (`verify-check` if unchanged; `PASS` → `NOT_RUN(verify_green)`), `git log --oneline {run_base_sha}..HEAD`.
2. Cumulative `review-loop` on `{run_base_sha}..HEAD` (excl. `initial_dirty_paths`): **only** on `>=2` completed tasks/post-task edits; if task receipts are `FRESH`, cap to **Cross-Cutting** (`git diff --stat`, contracts, duplication, residue) + post-task deltas (full diff if stale/missing); fixes need `verify-run` + `precommit --require-verify-receipt --expected-cmd <cmd> --relevant-paths <csv>` → 1 `final` commit.
3. Unignored run-dirty files block `PASS` (`INCOMPLETE`). Set `run_status` (`PASS`|`FAIL`|`INCOMPLETE`|`BLOCKED`); report `last_wave:`, ACs, SHAs, checks, review, unverified claims, `{RUN_DIR}/pr-body.md` ([pr-template.md](references/pr-template.md)); PR feedback: `pr-feedback/SKILL.md`.
