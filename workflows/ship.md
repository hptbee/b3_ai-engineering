# Ship lifecycle

End-to-end delivery from requirement/plan through verified commits until done or blocked.

```text
Preflight → Plan → wave/task: Scope (Gate + design-only) → Build → Verify → Review → Commit → Finalize
```

Links: [feature-impl](feature-implementation.md), [review-loop](../review-loop/strategy.md) (skip `spec.md`), [templates](references/ship-templates.md), [resume](references/ship-resume.md), [dispatch](references/dispatch-naming.md), [context-routing](references/context-routing.md), `b3-guard.{ps1,sh}`.

## Context, hosts & B3 roots

- **Use:** full run, `resume [<run_id>]`, `status [<run_id>|--all]`. **Not:** single-step cmds. Overrides `planning`/`problem-solving` stops (`precedence.md`).
- **Hosts:** Cursor/Claude (`/b3-ship`), Codex (`$b3-ship`), Antigravity (`b3-ship`); resume needs re-invocation.
- **Roots:** `PRODUCT_ROOT`=git root; `B3_HOME`=first dir with `workflows/ship.md` (repo, `B3_HOME` env, `{PRODUCT_ROOT}/.b3/home`; else `BLOCKED`). Load skills/rules/agents from `B3_HOME`; state/commits in `PRODUCT_ROOT`; never copy `skills/`.

## State & checkpoint git policy

Under `{PRODUCT_ROOT}/.b3/ship/`: `CURRENT` (1L `<run_id>`, `YYYYMMDD-HHMM-<slug>`, no symlink) + `runs/<run_id>/` (`{RUN_DIR}` via `b3-guard resolve-run`: `master-plan.md`, `progress.md`, `findings.md`, `approach/T00N.md`, `logs/`).
- **Hygiene:** read `CURRENT`→`{RUN_DIR}/` directly; never scan `.b3/ship/runs/` except `status --all` (`list-runs`) or `prune` (keeps 10 `PASS` + `CURRENT`/non-`PASS`).
1. Product repos ignore `.b3/ship/` (upgrade `.b3/` so `.b3/home` commits); B3 repo ignores `.b3/`.
2. Never `git add .b3/ship/`, `git add -A`, or `git add .`; run `b3-guard precommit` before every commit.
3. Ignored `.b3/` files never dirty tree; non-ignored files added in run block `PASS`.
4. **Thin Parent:** after `T00N` commits, collapse `## Approach` in `progress.md` to 1L; Parent reads summaries/diffs/contracts only, logs red `>35L` to `{RUN_DIR}/logs/`.

## Input & Preflight

1. `status [<run_id>|--all]` → `list-runs` (`--all`) or `resolve-run` + Git report, no edits.
2. `resume [<run_id>]`, or bare `/b3-ship` when `run_status != PASS` → **Scenario C** ([resume](references/ship-resume.md); update `CURRENT`).
3. No request/checkpoint → ask what to build (`BLOCKED`).
4. Plan/request/bug/refactor → `b3-guard new-run` (`CURRENT`), then **Scenario B** (plan) or **Scenario A** (`debugging`/`refactoring`).

### Scenario A / B (Preflight & Plan)

1. Restate request + inspected current/desired behavior (reuse code).
2. **Preflight:** record `initial_dirty_paths` + canonical `build`/`typecheck`/`lint`/`test` from CI/manifests. Run baseline at `run_base_sha` **background/on-demand if `Verify` fails** (never block `Plan`/`Scope`); set `baseline_status` (`PASS`|`FAIL(...)`|`NOT_RUN(verify_green)`).
3. **Plan:** write `{RUN_DIR}/master-plan.md` ([templates](references/ship-templates.md), `planning`+`simplest-correct`): 3–5 `Invariants`, `AC1..ACn`, verbatim contracts; hotspots (`package.json`/`.csproj`/`index.ts`/migrations/contracts) in task 1; split note if `>~800L`/`>=2 areas`; Scenario B keeps intent, marks `completed` only with Git proof, copies external plan once.
4. Execute directly. `BLOCKED` only for ambiguity, overlapping `initial_dirty_paths`, external ops (push/merge/deploy/destructive git/secrets/prod), or unasked breaking changes. Routine `>=4`-task/`auth`/`migration`/`shared` plans run autonomously (`detailed`).

## Execution

Record `run_id`, `b3_home`, `product_root`, `plan_id`, `plan_version`, `branch`, `run_base_sha`, `baseline_status`, `initial_dirty_paths`, `last_wave` in `progress.md` (reconstruct missing `run_base_sha` via Git, else `INCOMPLETE`). Evaluate ready tasks (`pending`, `depends_on` done) automatically per [dispatch](references/dispatch-naming.md): lowest id first if sequential, or disjoint wave; set `task_base`=`git rev-parse HEAD`, run **Scope** first.

### Scope (Just-in-Time planning + Gate)

Skip `planning`; use `skills/engineering/problem-solving/SKILL.md`:
1. Inspect scope, callers, contracts, schema, tests (`context-routing.md`/`context-cache` on demand); split **`files`** vs **`read_only_deps`**; **`watched_paths`**=`files`+`read_only_deps`. Record **`reuse:`**, **`obsoletes:`** (`none`).
2. **Depth:** `inline` (`progress.md`), `notes` (`approach/T00N.md`, multi-file), `detailed` (`approach/T00N.md`, API/schema/auth/migration/prod/new layer/`>=4`-task contracts; `failure_matrix:`, `write_paths:` `>=2` stores+invalidation, `io_budget:` loops).
3. **Evidence-based refinement:** if >1 commit, narrow task, add `T00N` slices, chain `depends_on`, retarget dependents, bump `version`/`plan_id`/`plan_version`, log `Plan changes`, continue Scope.
4. **Implementation Readiness Gate:** start `readiness: draft`; Empty template headings are not evidence. Set `readiness: ready` only when `inspected`, `files` (or new-file intent), `watched_paths`, `reuse`, `obsoletes`, `changes`, `verification`, `task_spec_fingerprint` (`b3-guard fingerprint`) are filled; record `approach_at_sha` (`git rev-parse HEAD`). Else `INCOMPLETE`.
5. **Pre-code Review (`detailed` only — no Debate):** run `b3-architecture-reviewer.md` (`design-only`, contrarian) + `b3-security-reviewer.md` (`design-only`; `dispatch-naming.md`) for auth/untrusted input/race/abuse. On `CONFIRMED` flaw: revise, reset `readiness: draft`, **re-run the Implementation Readiness Gate** before `Build`.

### Build (Subagents & Waves) & Verify

- **Build (Subagents & Waves):** dispatch `b3-impl-t00N` ([dispatch](references/dispatch-naming.md), optional `models.md`) for **every** ready task (1+, any depth; inline only if no subagents) so `implementation` overrides `main`. Automatically run `b3-guard check-wave -Partition` (`-WaveReads`, `-MaxConcurrency` `1..4` def `3`, `-ExpectedBaseSha`): `WAVE_OK`→parallel wave 1; `WAVE_PARTITIONED`→run wave 1 first, defer conflicts; `WAVE_SEQUENTIAL`/`WAVE_CONFLICT`, `<=1`/trivial task, or missing host isolation (`check-worktree`)→`SEQUENTIAL` (`no_host_isolation`/`sequential_host_fallback`; never report `PARALLEL`); `WAVE_BASE_MISMATCH`→`BLOCKED`/re-scope. Save `impl_agent` ID + `last_wave:` (`dispatch=PARALLEL|SEQUENTIAL ...`) in `progress.md` (single-writer Parent). `Context Packet`: `approach/T00N.md`/inline, `files`/`read_only_deps`, 1L `context_hint:`, smallest skill, verbatim contract (**never** `ship.md`/`master-plan.md`). Reply ≤25L (`files_changed`, `commands_run`, `obsoletes_removed`, `discoveries`, `change_requests`). On partial failure, keep valid outputs and isolate/recover failing tasks only.
- **Verify:** minimal edits (`problem-solving`+domain skill), delete `obsoletes`. Run `b3-guard verify-run` (`{RUN_DIR}/evidence/T00N.verify`, scoped `-RelevantPaths` on waves, logs >35L/red to `{RUN_DIR}/logs/`; reuse `verify-check`; no pipe masking): fix own reds; if baseline deferred, check `run_base_sha` and report prior reds.

### Review (Guard → Reviewer → Fix) & Commit

1. **Guard (0 tok):** `b3-guard diff-scope` (`-BaseSha {task_base}`, `-PrevSha {pre_fix_object}` Iter 2+; fallback `git diff --name-only {task_base}`, `git diff --cached --name-only`, `git ls-files --others --exclude-standard`) + `mechanical-check` (`-BaseSha`, `-AllowedPaths`, `-Obsoletes`) + `symbol-check` on refactors, excl. `.b3/ship/`, unchanged `initial_dirty_paths`, noise. Never `HEAD~1`. Fix `exit 2` (`safety_hits` → `BLOCKED`).
2. **Reviewer & Fix (Risk-tiered + lazy snapshot):** 1L `context_hint:` per `context-routing.md` (native fallback on MCP error): `inline`+`XS`/`S`+`LOW` → 1 fresh `b3-reviewer.md` pass (escalate on blocker); else [`../review-loop/strategy.md`](../review-loop/strategy.md) (`L`/`XL`/`XXL` adds `hierarchical.md`). Capture `pre_fix_object` (`b3-guard snapshot`) **only if blocking `CONFIRMED` exist before `Fix`**; resume `impl_agent` + 2-tier breaker (unisolated: `SINGLE_AGENT_LIMIT` hat-change — cannot emit `PASS`/`VERIFIED`/`MERGE_AUTHORIZED` on `HIGH`/`CRITICAL` → `INCOMPLETE`, blocks `auto_merge`).
3. **Commit:** single-writer sequential commits: require passing ACs, valid `verify-check`, 0 blocking `CONFIRMED`, diff in `files`/`tests`, no residue (`INCOMPLETE`/`FAIL`/`BLOCKED`). Run `b3-guard precommit -RequireVerifyReceipt {RUN_DIR}/evidence/T00N.verify`, commit once (no `--no-verify`/amend/reset/push/merge/deploy), record SHA+`completed`, collapse `T00N`. After parallel waves integrate, run post-integration `verify-run` + cross-unit review (`strategy.md`), then next wave.

## Finalize & Outcomes

When all required tasks are `completed`:
1. Verify `AC1..ACn` e2e, `Invariants`, full checks vs `baseline_status` (reuse `verify-check` if final tree unchanged; `PASS` sets deferred baseline `NOT_RUN(verify_green)`), and confirm commits descend into `HEAD` (`git log --oneline {run_base_sha}..HEAD`).
2. Cumulative `review-loop` on `{run_base_sha}..HEAD` (excl. unchanged `initial_dirty_paths`): **only if `>=2` tasks completed** (or post-review edits). Default **Cross-Cutting** (`git diff --stat` + boundaries/contracts/duplication); review edits need `verify-run` + `precommit -RequireVerifyReceipt` for 1 `final` commit.
3. Non-ignored dirty files added in run block `PASS` (`INCOMPLETE`). Set `run_status` (`PASS`|`FAIL`|`INCOMPLETE`|`BLOCKED`); report `last_wave:`, ACs, SHAs, checks, review, unverified claims, PR ([pr-template.md](references/pr-template.md)).
