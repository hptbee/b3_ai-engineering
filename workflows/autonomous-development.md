# Autonomous development

One invocation carries a requirement or plan through planning, coding, verification, review, and commits until done or blocked.

```text
Pre-flight (gitignore, initial_dirty_paths, baseline, new-run) → Plan
  → task/wave: JIT Analyze → Gate → [Pre-code Review] → Code/Test → Snapshot → Mechanical/Review/Fix → Guard → Commit
  → Final verification
```

Links: [`feature-implementation.md`](feature-implementation.md), [`../review-loop/strategy.md`](../review-loop/strategy.md) (self-sufficient; skip `spec.md`), [`references/autodev-templates.md`](references/autodev-templates.md), [`references/autodev-resume.md`](references/autodev-resume.md), CLI `scripts/autodev-guard.{ps1,sh}` (helper, not runner).

## Scope, hosts & B3 roots

- **Use:** full lifecycle, `resume [<run_id>]`, `status [<run_id>|--all]`. **Not for:** single plan/implement/debug/review/review-loop/verify. Overrides `planning`/`problem-solving` stops (`docs/precedence.md`).
- **Hosts:** Cursor (`/autodev`), Codex (`$autodev`), Antigravity (`autodev`), Claude (`/autodev`). Resume needs re-invocation.
- **Roots:** `PRODUCT_ROOT` = git root; `B3_HOME` = first dir with `workflows/autonomous-development.md` (this repo, `B3_HOME` env, `{PRODUCT_ROOT}/.b3/home`; else `BLOCKED`). Load skills/rules/agents from `B3_HOME`; checkpoints/commits stay in `PRODUCT_ROOT`; never copy `skills/`.

## State & checkpoint git policy

Under `{PRODUCT_ROOT}/.b3/autodev/`: `CURRENT` (1-line `<run_id>`, `YYYYMMDD-HHMM-<slug>`, no symlink) and `runs/<run_id>/` (`{RUN_DIR}` via `autodev-guard resolve-run`: `master-plan.md`, `progress.md`, sole `findings.md` — never `review-loop/state/current.yaml` — optional `approach/T00N.md`, `logs/`).
- **Token hygiene:** read `CURRENT` → `{RUN_DIR}/` directly; never scan `.b3/autodev/runs/` except `status --all` (`list-runs`) or `prune` (keeps 10 `PASS`; never deletes `CURRENT`/non-`PASS`).
1. Product repos ignore `.b3/autodev/` (upgrade bare `.b3/` so `.b3/home` commits); this repo ignores `.b3/`.
2. Never `git add .b3/autodev/`, `git add -A`, or `git add .`; run `autodev-guard precommit` before every commit.
3. Ignored `.b3/` files never dirty the tree; non-ignored files added during run block `PASS`.
4. **Compression:** after `T00N` commits, collapse its `## Approach` in `progress.md` to 1 line.

## Input & Pre-flight

1. `status [<run_id>|--all]` → `list-runs` on `--all`; else `resolve-run` + Git report, no edits.
2. `resume [<run_id>]`, or bare `/autodev` when `run_status != PASS` → **Scenario C** ([`references/autodev-resume.md`](references/autodev-resume.md); write `<run_id>` to `CURRENT`).
3. No requirement and no unfinished checkpoint → ask what to build (`BLOCKED`).
4. Plan/requirement/bug/refactor → `autodev-guard new-run` (updates `CURRENT`), then **Scenario B** (plan) or **Scenario A** (`debugging`/`refactoring`).

### Scenario A / B (Master plan & baseline)

1. Restate request and inspected current/desired behavior (reuse existing code).
2. **Pre-flight:** record `initial_dirty_paths` and canonical `build`/`typecheck`/`lint`/`test` from CI/hooks/manifests. Run baseline at `run_base_sha` (background ok; never swallow exit codes); record `baseline_status`.
3. Write/normalize `{RUN_DIR}/master-plan.md` per [`references/autodev-templates.md`](references/autodev-templates.md) (`planning` + `simplest-correct`): 3–5 `Invariants`, `AC1..ACn`, verbatim shared contracts (API/types/events copied identically — never paraphrase); assign hotspots (`package.json`, `.csproj`, `index.ts`, migrations, shared contracts) to 1 foundational task committed first; add 1-line split warning if `> ~800L` or `>= 2 areas`; on Scenario B keep intent, mark `completed` only with Git/code proof, copy external plan once.
4. Enter **Execution** directly. `BLOCKED` only for business ambiguity, overlapping `initial_dirty_paths`, external ops (push/merge/deploy/destructive git/secrets/prod data), or unrequested breaking changes. Routine `>= 4`-task or `auth`/`migration`/`shared` plans stay autonomous (`depth: detailed`).

## Execution

Record `run_id`, `b3_home`, `product_root`, `plan_id`, `plan_version`, `branch`, `run_base_sha`, `baseline_status`, `initial_dirty_paths` in `progress.md` (reconstruct missing `run_base_sha` from Git, else `INCOMPLETE`). Run ready tasks (`pending`, `depends_on` `completed`) lowest id first (or disjoint wave); set `task_base` = `git rev-parse HEAD`, run **Analyze** first.

### Analyze (Just-in-Time planning)

Skip `planning`; use `skills/engineering/problem-solving/SKILL.md`:
1. Inspect scope, callers, contracts, schema, tests; split **`files`** vs **`read_only_deps`**; **`watched_paths`** = `files` + `read_only_deps`. Record **`reuse:`** and **`obsoletes:`** (or `none`).
2. **Depth:** `inline` (`progress.md`, small), `notes` (`approach/T00N.md`, multi-file), `detailed` (`approach/T00N.md`, public API/schema/auth/migration/prod data/new layer/`>= 4`-task shared contracts; fill `write_paths:` for `>= 2` stores + invalidation, `io_budget:` for query/list/render loops, stateful/race/auth `edge_cases:`).
3. **Evidence-based refinement:** if >1 commit, narrow task, add unused `T00N` slices, chain `depends_on`, retarget dependents, bump `version`/`plan_id`/`plan_version`, log under `Plan changes`, continue Analyze.
4. **Implementation Readiness Gate:** start `readiness: draft`; Empty template headings are not evidence. Set `readiness: ready` only when `inspected`, `files` (or new-file intent), `watched_paths`, `reuse`, `obsoletes`, `changes`, `verification`, `task_spec_fingerprint` (`autodev-guard fingerprint`) are non-empty (`data_flow` may be `n/a` + reason). Record `approach_at_sha` (`git rev-parse HEAD`). Incomplete → `INCOMPLETE`.
5. **1-Pass Pre-code Review (`detailed` only — no Debate):** dispatch `architecture-reviewer.md` (`design-only`, contrarian) + `security-reviewer.md` (`design-only`) for auth/untrusted input/race/abuse. Never name a product diff. On `CONFIRMED` flaws, revise, reset `readiness: draft`, **re-run the Implementation Readiness Gate** before `Implement`.

### Implement, Parallel Waves, Test & Snapshot

- **Subagent-per-task & Parallel Waves:** on `>= 2` ready tasks (`notes`/`detailed`), Parent may launch 2–3 workers in ONE turn (never poll) **only** after `autodev-guard check-wave` returns `WAVE_OK` (disjoint `files`; isolated workspace preferred, else repo-wide checks post-wave). Save `impl_agent` in `progress.md` to **resume** owning worker with deltas on Fix/contract updates (prompt cache). Workers read **only** their task `approach/T00N.md` (or inline approach), `files`/`read_only_deps`, and smallest domain skill — **never** load `autonomous-development.md` or `master-plan.md`; pass paths + verbatim shared contract only (no standing rules). Reply ≤ 25 lines: `files_changed`, `commands_run` (exit codes), `obsoletes_removed`, `discoveries`, `change_requests` (`none` if empty). Workers **never** talk directly or edit `read_only_deps`/contracts — Parent is sole Hub.
- **Scoped Verify & Snapshot:** minimal edits (`problem-solving` + smallest domain skill), delete `obsoletes`. Run scoped `VERIFY` (no pipe exit-code swallowing; 1 line green, ≤ 35 failing lines red or log to `{RUN_DIR}/logs/`): fix self-caused failures; **report (don't fix)** unowned/`baseline_status` failures. Once green (before `Fix`), capture `pre_fix_object` (`autodev-guard snapshot`).

### Mechanical Pass, Review, Fix, Gate & Commit

1. **Diff scope & Mechanical Pass (0 tokens):** run `autodev-guard diff-scope` (`-BaseSha {task_base}`, `-PrevSha {pre_fix_object}` Iter 2+; fallback: `git diff --name-only {task_base}`, `git diff --cached --name-only`, `git ls-files --others --exclude-standard`) + `autodev-guard mechanical-check` (`-BaseSha`, `-AllowedPaths`, `-Obsoletes`), excluding `.b3/autodev/`, unchanged `initial_dirty_paths`, noise. Never `HEAD~1`. Fix `scope_creep`/`leftovers`/`obsolete_hits` (`exit 2`) first.
2. **Risk-tiered Review:** `depth: inline` + `SMALL` diff (no auth/contract/schema/hot-path) → 1 fresh `reviewer.md` pass (escalate on blocking `CONFIRMED`). Else [`../review-loop/strategy.md`](../review-loop/strategy.md) (independent Reviewer, resume `impl_agent` on Fix with bug-class sweep + 2-tier breaker; log hat-change if unisolated).
3. **Gate & Commit:** require passing ACs, executed checks, 0 blocking `CONFIRMED`, diff in declared `files`/`tests`, no residue (`INCOMPLETE` missing evidence; `FAIL` red check/defect; `BLOCKED` overlapping `initial_dirty_paths`/user decision). Commit sequentially: `autodev-guard precommit`, commit once (no `--no-verify`/amend/reset/push/merge/deploy), record SHA + `completed`, collapse `T00N`, start next task/wave.

## Final verification & Outcomes

When all required tasks are `completed`:
1. Verify `AC1..ACn`, `Invariants`, full checks vs `baseline_status`, and all `completed` commits descend into `HEAD` (`git log --oneline {run_base_sha}..HEAD`).
2. Cumulative `review-loop` on `{run_base_sha}..HEAD` (excl. unchanged `initial_dirty_paths`): default **Cross-Cutting** (`git diff --stat` + boundary/multi-task files, contracts, duplication) if all tasks passed review. Final fixes get 1 commit (`final`).
3. Non-ignored dirty files added in run block `PASS` (`INCOMPLETE`). Set `run_status` (`PASS`|`FAIL`|`INCOMPLETE`|`BLOCKED`) and report ACs, SHAs, checks vs baseline, review, remaining issues, unverified claims, PR readiness.
