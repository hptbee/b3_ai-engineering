# Ship lifecycle

End-to-end delivery from requirement or plan through verified commits until done or blocked.

```text
Preflight (gitignore, initial_dirty_paths, checks, new-run) → Plan
  → task/wave: Scope (Gate + optional design-only) → Build → Verify → Review (0-tok Guard → Reviewer → Fix) → Commit
  → Finalize
```

Links: [`feature-implementation.md`](feature-implementation.md), [`../review-loop/strategy.md`](../review-loop/strategy.md) (skip `spec.md`), [`references/ship-templates.md`](references/ship-templates.md), [`references/ship-resume.md`](references/ship-resume.md), CLI `scripts/b3-guard.{ps1,sh}`.

## Context, hosts & B3 roots

- **Use:** full run, `resume [<run_id>]`, `status [<run_id>|--all]`. **Not:** single plan/impl/debug/review/loop/verify. Overrides `planning`/`problem-solving` stops (`docs/precedence.md`).
- **Hosts:** Cursor (`/b3-ship`), Codex (`$b3-ship`), Antigravity (`b3-ship`), Claude (`/b3-ship`). Resume needs re-invocation.
- **Roots:** `PRODUCT_ROOT` = git root; `B3_HOME` = first dir with `workflows/ship.md` (this repo, `B3_HOME` env, `{PRODUCT_ROOT}/.b3/home`; else `BLOCKED`). Load skills/rules/agents from `B3_HOME`; checkpoints/commits stay in `PRODUCT_ROOT`; never copy `skills/`.

## State & checkpoint git policy

Under `{PRODUCT_ROOT}/.b3/ship/`: `CURRENT` (1-line `<run_id>`, `YYYYMMDD-HHMM-<slug>`, no symlink) and `runs/<run_id>/` (`{RUN_DIR}` via `b3-guard resolve-run`: `master-plan.md`, `progress.md`, sole `findings.md`, optional `approach/T00N.md`, `logs/`).
- **Token hygiene:** read `CURRENT` → `{RUN_DIR}/` directly; never scan `.b3/ship/runs/` except `status --all` (`list-runs`) or `prune` (keeps 10 `PASS`; never deletes `CURRENT`/non-`PASS`).
1. Product repos ignore `.b3/ship/` (upgrade `.b3/` so `.b3/home` commits); B3 repo ignores `.b3/`.
2. Never `git add .b3/ship/`, `git add -A`, or `git add .`; run `b3-guard precommit` before every commit.
3. Ignored `.b3/` files never dirty the tree; non-ignored files added during run block `PASS`.
4. **Thin Parent:** after `T00N` commits, collapse `## Approach` in `progress.md` to 1L; delegated Parent reads only summaries/diffs/contracts (no full files) and logs red `>35L` to `{RUN_DIR}/logs/`.

## Input & Preflight

1. `status [<run_id>|--all]` → `list-runs` on `--all`; else `resolve-run` + Git report, no edits.
2. `resume [<run_id>]`, or bare `/b3-ship` when `run_status != PASS` → **Scenario C** ([`references/ship-resume.md`](references/ship-resume.md); write `<run_id>` to `CURRENT`).
3. No requirement and no unfinished checkpoint → ask what to build (`BLOCKED`).
4. Plan/requirement/bug/refactor → `b3-guard new-run` (updates `CURRENT`), then **Scenario B** (plan) or **Scenario A** (`debugging`/`refactoring`).

### Scenario A / B (Preflight & Plan)

1. Restate request + inspected current/desired behavior (reuse code).
2. **Preflight:** record `initial_dirty_paths` and canonical `build`/`typecheck`/`lint`/`test` from CI/manifests. Run baseline at `run_base_sha` **background/on-demand if `Verify` fails** (never block `Plan`/`Scope` or swallow exit codes); set `baseline_status` (`PASS`|`FAIL(...)`|`NOT_RUN(verify_green)`).
3. **Plan:** write `{RUN_DIR}/master-plan.md` via [`references/ship-templates.md`](references/ship-templates.md) (`planning`+`simplest-correct`): 3–5 `Invariants`, `AC1..ACn`, verbatim shared contracts; put hotspots (`package.json`, `.csproj`, `index.ts`, migrations, contracts) in task 1; add split note if `>~800L`/`>=2 areas`; on Scenario B keep intent, mark `completed` only with Git proof, copy external plan once.
4. Start Execution directly. `BLOCKED` only for ambiguity, overlapping `initial_dirty_paths`, external ops (push/merge/deploy/destructive git/secrets/prod), or unasked breaking changes. Routine `>=4`-task/`auth`/`migration`/`shared` plans run autonomously (`detailed`).

## Execution

Record `run_id`, `b3_home`, `product_root`, `plan_id`, `plan_version`, `branch`, `run_base_sha`, `baseline_status`, `initial_dirty_paths` in `progress.md` (reconstruct missing `run_base_sha` from Git, else `INCOMPLETE`). Run ready tasks (`pending`, `depends_on` `completed`) lowest id first (or disjoint wave); set `task_base` = `git rev-parse HEAD`, run **Scope** first.

### Scope (Just-in-Time planning + Gate)

Skip `planning`; use `skills/engineering/problem-solving/SKILL.md`:
1. Inspect scope, callers, contracts, schema, tests; split **`files`** vs **`read_only_deps`**; **`watched_paths`** = `files` + `read_only_deps`. Record **`reuse:`** and **`obsoletes:`** (or `none`).
2. **Depth:** `inline` (`progress.md` lean), `notes` (`approach/T00N.md`, multi-file), `detailed` (`approach/T00N.md`, API/schema/auth/migration/prod/new layer/`>=4`-task contracts; risk-triggered `failure_matrix:`, `write_paths:` for `>=2` stores+invalidation, `io_budget:` for query/render loops).
3. **Evidence-based refinement:** if >1 commit, narrow task, add unused `T00N` slices, chain `depends_on`, retarget dependents, bump `version`/`plan_id`/`plan_version`, log under `Plan changes`, continue Scope.
4. **Implementation Readiness Gate:** start `readiness: draft`; Empty template headings are not evidence. Set `readiness: ready` only when `inspected`, `files` (or new-file intent), `watched_paths`, `reuse`, `obsoletes`, `changes`, `verification`, `task_spec_fingerprint` (`b3-guard fingerprint`) are filled; record `approach_at_sha` (`git rev-parse HEAD`). Else `INCOMPLETE`.
5. **Pre-code Review (`detailed` only — no Debate):** run `b3-architecture-reviewer.md` (`design-only`, contrarian) + `b3-security-reviewer.md` (`design-only`; per `dispatch-naming.md`) for auth/untrusted input/race/abuse (no diff). On `CONFIRMED` flaw: revise, reset `readiness: draft`, **re-run the Implementation Readiness Gate** before `Build`.

### Build (Subagents & Waves) & Verify

- **Build (Subagents):** dispatch `b3-impl-t00N` ([dispatch](references/dispatch-naming.md), optional `models.md`) for **every** ready task (1+ tasks, any depth; inline only without subagents) so `implementation` model overrides `main`. Launch 2–3 in 1 turn (no poll) **only** after `b3-guard check-wave` (`-WaveReads`, `-ExpectedBaseSha`) → `WAVE_OK` (+ `check-worktree` if isolated; else sequential). Save `impl_agent` ID in `progress.md` (Fix cache). Brief via `Context Packet` (`ship-templates.md`): `approach/T00N.md`/inline, `files`/`read_only_deps`, smallest skill, verbatim contract; **never** `ship.md`/`master-plan.md`. Reply ≤ 25L: `files_changed`, `commands_run`, `obsoletes_removed`, `discoveries`, `change_requests` (`none` if empty). Parent is Hub.
- **Verify:** minimal edits (`problem-solving`+domain skill), delete `obsoletes`. Run checks via `b3-guard verify-run` (`{RUN_DIR}/evidence/T00N.verify`, scoped `-RelevantPaths` on waves, logs >35L/red to `{RUN_DIR}/logs/`; reuse `verify-check`; no pipe masking): fix own reds; if red and baseline deferred, check `run_base_sha` and report (don't fix) prior reds.

### Review (Guard → Reviewer → Fix) & Commit

1. **Guard (0 tokens):** run `b3-guard diff-scope` (`-BaseSha {task_base}`, `-PrevSha {pre_fix_object}` Iter 2+; fallback: `git diff --name-only {task_base}`, `git diff --cached --name-only`, `git ls-files --others --exclude-standard`) + `mechanical-check` (`-BaseSha`, `-AllowedPaths`, `-Obsoletes`) + `symbol-check` on refactors (`notes`/`detailed`), excluding `.b3/ship/`, unchanged `initial_dirty_paths`, noise. Never `HEAD~1`. Fix `exit 2` hits (`safety_hits` destructive/secret → `BLOCKED` unless approved).
2. **Reviewer & Fix (Risk-tiered + lazy snapshot):** `inline`+`XS`/`S`+`LOW` risk → 1 fresh `b3-reviewer.md` pass (per `dispatch-naming.md`, escalate on blocker). Else [`../review-loop/strategy.md`](../review-loop/strategy.md) (`L`/`XL`/`XXL` adds `hierarchical.md`). Capture `pre_fix_object` (`b3-guard snapshot`) **only if blocking `CONFIRMED` items exist and before `Fix`** (skip Pass-1 clean); resume `impl_agent` with bug-class sweep + 2-tier breaker (log hat-change if unisolated).
3. **Commit:** require passing ACs, valid `verify-check` receipt, 0 blocking `CONFIRMED`, diff in `files`/`tests`, no residue (`INCOMPLETE` missing/stale receipt; `FAIL` red/defect; `BLOCKED` dirty overlap/decision). Commit sequentially: `b3-guard precommit -RequireVerifyReceipt {RUN_DIR}/evidence/T00N.verify`, commit once (no `--no-verify`/amend/reset/push/merge/deploy), record SHA + `completed`, collapse `T00N`, next task/wave.

## Finalize & Outcomes

When all required tasks are `completed`:
1. Verify `AC1..ACn` end-to-end, `Invariants`, full checks vs `baseline_status` (reuse valid `verify-check` if final task tree unchanged across commits; `PASS` sets deferred baseline to `NOT_RUN(verify_green)`), and confirm `completed` commits descend into `HEAD` (`git log --oneline {run_base_sha}..HEAD`).
2. Cumulative `review-loop` on `{run_base_sha}..HEAD` (excl. unchanged `initial_dirty_paths`): **only if `>=2` tasks completed** (or post-review edits; skip duplicate 1-task re-review). Default **Cross-Cutting** (`git diff --stat` + boundaries, contracts, duplication); review edits need `verify-run` + `precommit -RequireVerifyReceipt` for 1 `final` commit.
3. Non-ignored dirty files added in run block `PASS` (`INCOMPLETE`). Set `run_status` (`PASS`|`FAIL`|`INCOMPLETE`|`BLOCKED`); report ACs, SHAs, checks vs baseline, review, issues, unverified claims, PR ([pr-template.md](references/pr-template.md)).
