# Autonomous development

One invocation runs a requirement or plan through planning, implementation, verification, review, and focused commits until done or blocked. Host entries select this file without duplicating it.

```text
Pre-flight (gitignore, initial_dirty_paths, baseline) → Plan (master-plan)
  → per ready task: JIT Analyze → Readiness Gate → [Pre-code Review]
    → Implement → Test → Pre-fix Snapshot → Review/Fix → Pre-commit Guard → Commit
  → Final verification
```

Links: [`feature-implementation.md`](feature-implementation.md), [`../review-loop/strategy.md`](../review-loop/strategy.md), [`../review-loop/spec.md`](../review-loop/spec.md), [`../review-loop/sizing.md`](../review-loop/sizing.md), [`references/autodev-templates.md`](references/autodev-templates.md), [`references/autodev-resume.md`](references/autodev-resume.md), guard CLI `scripts/autodev-guard.{ps1,sh}` (helper, not a runner).

## Scope, hosts & B3 roots

- **Use:** full lifecycle, `resume`, `status`. **Not for:** plan-only, single implement, debug-only, single review, review-loop-only, verify-only. Invocation overrides `planning`/`problem-solving` stops (`docs/precedence.md`).
- **Hosts:** Cursor (`/autodev`), Codex (`$autodev`), Antigravity (`autodev`), Claude Code (`/autodev`). Details: `adapters/{cursor,codex,antigravity,claude}/README.md`. Stopped sessions resume only on re-invocation.
- **Roots:** `PRODUCT_ROOT` = target git root; `B3_HOME` = first dir with `workflows/autonomous-development.md` (this repo, `B3_HOME` env, or `{PRODUCT_ROOT}/.b3/home`; else `BLOCKED`). Load skills/rules/agents from `B3_HOME`; checkpoints/commits stay in `PRODUCT_ROOT`; never copy `skills/`.

## State & checkpoint git policy

Checkpoints: `{PRODUCT_ROOT}/.b3/autodev/` (`master-plan.md`, `progress.md`, `findings.md`, optional `approach/T00N.md`). `findings.md` is the sole finding log (`R001`… monotonic; never write `review-loop/state/current.yaml`).
1. Product repos ignore `.b3/autodev/` (upgrading bare `.b3/` so `.b3/home` commits); this system repo ignores `.b3/`.
2. Never `git add .b3/autodev/`, `git add -A`, or `git add .`. Verify staging via `scripts/autodev-guard.{ps1,sh} precommit` or `git diff --cached --name-only` before commit.
3. Ignored `.b3/` files never dirty the tree; non-ignored files added during the run block `PASS`.
4. **Checkpoint compression:** after `T00N` commits, collapse its `## Approach` entry in `progress.md` to 1 line (O(1) size).

## Input & Pre-flight

1. `status` → report `.b3/autodev/` + Git, no edits.
2. `resume`, or no new requirement with `.b3/autodev/progress.md` → **Scenario C** ([`references/autodev-resume.md`](references/autodev-resume.md)).
3. No requirement and no checkpoint → ask what to build (`BLOCKED`).
4. Existing plan → **Scenario B**; requirement/bug/refactor → **Scenario A** (`debugging` for unknown cause; `refactoring` for restructure).

### Scenario A / B (Master plan & baseline)

1. Restate request and inspected current/desired behavior (reuse existing code).
2. **Pre-flight:** record `initial_dirty_paths` (non-ignored dirty/untracked paths) and canonical `build`/`typecheck`/`lint`/`test` from CI/hooks/manifests (no custom advisory lint). Run baseline at `run_base_sha` (background while planning or pre-`T001`) and record `baseline_status` in `progress.md`.
3. Write/normalize `.b3/autodev/master-plan.md` per [`references/autodev-templates.md`](references/autodev-templates.md) (`planning` + `simplest-correct`):
   - Include 3–5 `Invariants` and numbered `AC1..ACn` per task.
   - **Contract-first & Hotspots:** assign `package.json`, `.csproj`, `index.ts`, migrations, and shared contracts to one foundational task committed first.
   - **Size check:** estimate vs `review-loop/sizing.md`; if `> ~800 lines` or `>= 2 independent areas`, add a 1-line split warning without pausing cohesive features.
   - Scenario B: keep intent; mark `completed` only with Git/code proof; copy external plan once.
4. Enter **Execution** directly. `BLOCKED` only for business ambiguity, overlapping `initial_dirty_paths`, external ops (push/merge/deploy/destructive git/secrets/prod data), or unrequested destructive/breaking changes (data-loss drops, weakening authz, breaking public APIs). Routine `>= 4`-task or `auth`/`migration`/`shared` plans stay autonomous (`depth: detailed`).

## Execution

Record `b3_home`, `product_root`, `plan_id`, `plan_version`, `branch`, `run_base_sha`, `baseline_status`, and `initial_dirty_paths` in `progress.md` (reconstruct missing `run_base_sha` only from Git, else `INCOMPLETE`). Run ready tasks (`pending`, all `depends_on` `completed`) lowest id first. Set `task_base` = `git rev-parse HEAD` and run **Analyze** before editing.

### Analyze (Just-in-Time planning)

Do not load `planning` or write a second master plan. Use `skills/engineering/problem-solving/SKILL.md` Understand/Plan:
1. Inspect scope, callers, contracts, schema, and tests; split writable **`files`** (owned) from **`read_only_deps`** (do not edit); **`watched_paths`** = `files` + `read_only_deps` (real paths only).
2. Record **`reuse:`** (existing helpers/DTOs) and **`obsoletes:`** (dead paths/fallbacks to delete, or `none`).
3. Pick **depth:** `inline` (`progress.md`, small single-area), `notes` (`approach/T00N.md`, multi-file/local contract), `detailed` (`approach/T00N.md`, public API/schema/auth/migration/prod data/new layer/`>= 4`-task shared contracts). On `detailed`, fill conditional `write_paths:` (`>= 2` stores + cache invalidation), `io_budget:` (query/list/render loop), and stateful/race/auth `edge_cases:`.
4. **Evidence-based refinement:** if inspection proves a task cannot be one commit, narrow the original id, add slices at next unused `T00N` ids, chain `depends_on` and retarget dependents, bump `version`/`plan_id`/`plan_version`, log under `Plan changes`, and continue Analyze.
5. **Implementation Readiness Gate:** templates start at `readiness: draft`; empty template headings are not evidence. Set `readiness: ready` only when `inspected`, `files` (or new-file intent), `watched_paths`, `reuse`, `obsoletes`, `changes`, `verification`, and `task_spec_fingerprint` (`scripts/autodev-guard.{ps1,sh} fingerprint`) are non-empty (`data_flow` may be `n/a` with reason). Record `approach_at_sha` (`git rev-parse HEAD`). Incomplete inspection → `INCOMPLETE`.
6. **1-Pass Pre-code Risk Review (`detailed` only — no Debate Round):** with host isolation and non-empty approach, dispatch `architecture-reviewer.md` (`design-only`) — plus `security-reviewer.md` (`design-only`) in parallel for auth/untrusted input/race/abuse. Never name a product diff. On `CONFIRMED` flaws, revise, reset `readiness: draft`, and **re-run the Implementation Readiness Gate** before `Implement`.

### Implement, Test & Pre-fix Snapshot

- **Context budget & `Subagent-per-task`:** on `>= 3`-task runs (`notes`/`detailed`), parent may stay thin orchestrator and delegate `Implement + Test` to a clean subagent bounded by `files`, `read_only_deps`, `reuse`, `obsoletes` (pass paths, not file dumps; cap reply ≤ 25 lines: `files_changed`, `commands_run` + exit codes, `obsoletes_removed`). Keep summary line only on passing tests; on failure keep first ~40 failing lines or log to `.b3/autodev/logs/`.
- **Implement & Test:** minimal edits (`problem-solving` + smallest domain skill), delete confirmed `obsoletes`, run task + canonical checks vs `baseline_status` (`testing-strategy` + `verification`).
- **Pre-fix Snapshot:** once green (before `Fix`), record `pre_fix_object` via `scripts/autodev-guard.{ps1,sh} snapshot` (`git stash create`, fallback `HEAD`) without touching working tree or stash list.

### Review, Fix, Gate & Commit

1. **Diff scope:** run `scripts/autodev-guard.{ps1,sh} diff-scope -BaseSha {task_base} -IgnoreDirtyPaths {initial_dirty_paths}` (or `git diff --name-only {task_base}`, `git diff --cached --name-only`, `git ls-files --others --exclude-standard`, `git status --porcelain`), excluding `.b3/autodev/`, unchanged `initial_dirty_paths`, and lockfile/generated noise. Never substitute `HEAD~1`.
2. **Risk-tiered Review:** `depth: inline` + `SMALL` diff (no auth/contract/schema/hot-path) → 1 independent `reviewer.md` pass (escalate to full `review-loop` only on a blocking `CONFIRMED` finding). Otherwise run [`../review-loop/strategy.md`](../review-loop/strategy.md) with active-only `findings.md` slices and compact replies.
3. **Quality gate & Commit:** require passing ACs, executed checks, 0 blocking `CONFIRMED` findings, diff in declared `files`/`tests`, no confirmed residue. Missing evidence → `INCOMPLETE`; failed check/confirmed defect → `incomplete`/`FAIL`; overlapping `initial_dirty_paths`/user decision → `blocked`/`BLOCKED`. Verify staging via `scripts/autodev-guard.{ps1,sh} precommit`, commit once (no `--no-verify`, amend, reset, push, merge, deploy), record SHA + `completed`, collapse `T00N` approach in `progress.md`, and **immediately** start the next ready task.

## Final verification & Outcomes

When all required tasks are `completed`:
1. Verify all `AC1..ACn` and `Invariants`, run full regression/build/typecheck vs `baseline_status`, and confirm every `completed` commit is an ancestor of `HEAD` in `git log --oneline {run_base_sha}..HEAD`.
2. Run cumulative `review-loop` on `{run_base_sha}..HEAD` (excluding unchanged `initial_dirty_paths`): when all tasks already passed independent review, default to **Cross-Cutting mode** (`git diff --stat` + boundary/multi-task files, contracts, cross-task duplication). Final cross-task fixes get one commit under `final`.
3. Non-ignored dirty files added during the run block `PASS` (`INCOMPLETE`). Set `run_status` (`PASS` | `FAIL` | `INCOMPLETE` | `BLOCKED`) and report ACs, task SHAs, checks vs baseline, review result, remaining issues, unverified claims, and PR readiness.
