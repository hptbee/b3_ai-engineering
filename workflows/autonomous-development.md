# Autonomous development

One invocation carries a requirement or plan through planning, coding, verification, review, and focused commits until done or blocked.

```text
Pre-flight (gitignore, initial_dirty_paths, baseline, new-run) → Plan
  → per task: JIT Analyze → Gate → [Pre-code Review] → Code/Test → Snapshot → Review/Fix → Guard → Commit
  → Final verification
```

Links: [`feature-implementation.md`](feature-implementation.md), [`../review-loop/strategy.md`](../review-loop/strategy.md) (self-sufficient; skip `spec.md`), [`references/autodev-templates.md`](references/autodev-templates.md), [`references/autodev-resume.md`](references/autodev-resume.md), CLI `scripts/autodev-guard.{ps1,sh}` (helper, not a runner).

## Scope, hosts & B3 roots

- **Use:** full lifecycle, `resume [<run_id>]`, `status [<run_id>|--all]`. **Not for:** single plan/implement/debug/review/review-loop/verify. Overrides `planning`/`problem-solving` stops (`docs/precedence.md`).
- **Hosts:** Cursor (`/autodev`), Codex (`$autodev`), Antigravity (`autodev`), Claude Code (`/autodev`). Resume requires re-invocation.
- **Roots:** `PRODUCT_ROOT` = target git root; `B3_HOME` = first dir with `workflows/autonomous-development.md` (this repo, `B3_HOME` env, or `{PRODUCT_ROOT}/.b3/home`; else `BLOCKED`). Load skills/rules/agents from `B3_HOME`; checkpoints/commits stay in `PRODUCT_ROOT`; never copy `skills/`.

## State & checkpoint git policy

Checkpoints under `{PRODUCT_ROOT}/.b3/autodev/`:
- `CURRENT`: 1-line `<run_id>` (`YYYYMMDD-HHMM-<slug>`, never symlink).
- `runs/<run_id>/` (`{RUN_DIR}` via `autodev-guard resolve-run`): `master-plan.md`, `progress.md`, `findings.md` (sole monotonic `R001`… log; never write `review-loop/state/current.yaml`), optional `approach/T00N.md`, `logs/`.
- **Token hygiene:** read `CURRENT` → `{RUN_DIR}/` directly. Never scan `.b3/autodev/runs/` except on `status --all` (`list-runs`) or `prune` (keeps newest 10 `PASS` runs; never deletes `CURRENT` or non-`PASS`).
1. Product repos ignore `.b3/autodev/` (upgrading bare `.b3/` so `.b3/home` commits); this repo ignores `.b3/`.
2. Never `git add .b3/autodev/`, `git add -A`, or `git add .`. Run `autodev-guard precommit` before every commit.
3. Ignored `.b3/` files never dirty the tree; non-ignored files added during the run block `PASS`.
4. **Compression:** after `T00N` commits, collapse its `## Approach` entry in `{RUN_DIR}/progress.md` to 1 line.

## Input & Pre-flight

1. `status [<run_id>|--all]` → `list-runs` on `--all`; else `resolve-run` + Git report, no edits.
2. `resume [<run_id>]`, or bare `/autodev` when `resolve-run` finds `run_status != PASS` → **Scenario C** ([`references/autodev-resume.md`](references/autodev-resume.md); write explicit `<run_id>` to `CURRENT`).
3. No requirement and no unfinished checkpoint (missing or `PASS`) → ask what to build (`BLOCKED`).
4. Plan or requirement/bug/refactor → allocate `{RUN_DIR}` via `autodev-guard new-run` (updates `CURRENT`), then **Scenario B** (existing plan) or **Scenario A** (`debugging` for unknown cause; `refactoring` for restructure).

### Scenario A / B (Master plan & baseline)

1. Restate request and inspected current/desired behavior (reuse existing code).
2. **Pre-flight:** record `initial_dirty_paths` (non-ignored dirty/untracked) and canonical `build`/`typecheck`/`lint`/`test` from CI/hooks/manifests. Run baseline at `run_base_sha`; record `baseline_status` in `{RUN_DIR}/progress.md`.
3. Write/normalize `{RUN_DIR}/master-plan.md` per [`references/autodev-templates.md`](references/autodev-templates.md) (`planning` + `simplest-correct`): 3–5 `Invariants` and `AC1..ACn` per task; assign hotspots (`package.json`, `.csproj`, `index.ts`, migrations, shared contracts) to one foundational task committed first; add 1-line split warning if `> ~800 lines` or `>= 2 independent areas`; on Scenario B keep intent, mark `completed` only with Git/code proof, and copy external plan once.
4. Enter **Execution** directly. `BLOCKED` only for business ambiguity, overlapping `initial_dirty_paths`, external ops (push/merge/deploy/destructive git/secrets/prod data), or unrequested destructive/breaking changes (data-loss drops, weakening authz, breaking public APIs). Routine `>= 4`-task or `auth`/`migration`/`shared` plans stay autonomous (`depth: detailed`).

## Execution

Record `run_id`, `b3_home`, `product_root`, `plan_id`, `plan_version`, `branch`, `run_base_sha`, `baseline_status`, and `initial_dirty_paths` in `{RUN_DIR}/progress.md` (reconstruct missing `run_base_sha` only from Git, else `INCOMPLETE`). Run ready tasks (`pending`, all `depends_on` `completed`) lowest id first; set `task_base` = `git rev-parse HEAD` and run **Analyze** before editing.

### Analyze (Just-in-Time planning)

Skip `planning` here; use `skills/engineering/problem-solving/SKILL.md` Understand/Plan:
1. Inspect scope, callers, contracts, schema, and tests; split writable **`files`** from **`read_only_deps`** (no edits); **`watched_paths`** = `files` + `read_only_deps` (real paths). Record **`reuse:`** and **`obsoletes:`** (or `none`).
2. Pick **depth:** `inline` (`progress.md`, small single-area), `notes` (`{RUN_DIR}/approach/T00N.md`, multi-file/local contract), `detailed` (`{RUN_DIR}/approach/T00N.md`, public API/schema/auth/migration/prod data/new layer/`>= 4`-task shared contracts; fill `write_paths:` for `>= 2` stores + invalidation, `io_budget:` for query/list/render loops, and stateful/race/auth `edge_cases:`).
3. **Evidence-based refinement:** if a task cannot be one commit, narrow it, add slices at next unused `T00N` ids, chain `depends_on` and retarget dependents, bump `version`/`plan_id`/`plan_version`, log under `Plan changes`, and continue Analyze.
4. **Implementation Readiness Gate:** templates start at `readiness: draft`; Empty template headings are not evidence. Set `readiness: ready` only when `inspected`, `files` (or new-file intent), `watched_paths`, `reuse`, `obsoletes`, `changes`, `verification`, and `task_spec_fingerprint` (`autodev-guard fingerprint`) are non-empty (`data_flow` may be `n/a` with reason). Record `approach_at_sha` (`git rev-parse HEAD`). Incomplete inspection → `INCOMPLETE`.
5. **1-Pass Pre-code Risk Review (`detailed` only — no Debate):** with host isolation and non-empty approach, dispatch `architecture-reviewer.md` (`design-only`) — plus `security-reviewer.md` (`design-only`) in parallel for auth/untrusted input/race/abuse. Never name a product diff. On `CONFIRMED` flaws, revise, reset `readiness: draft`, and **re-run the Implementation Readiness Gate** before `Implement`.

### Implement, Test & Pre-fix Snapshot

- **`Subagent-per-task` (`>= 3` tasks, `notes`/`detailed`):** parent may delegate `Implement + Test` to a clean subagent bounded by `files`, `read_only_deps`, `reuse`, `obsoletes` (pass paths, not file dumps; cap reply ≤ 25 lines: `files_changed`, `commands_run` + exit codes, `obsoletes_removed`). Keep 1 line on green checks; ≤ 35 failing lines on red or log to `{RUN_DIR}/logs/`.
- **Implement, Test & Snapshot:** minimal edits (`problem-solving` + smallest domain skill), delete confirmed `obsoletes`, verify against `baseline_status` (`testing-strategy` + `verification`). Once green (before `Fix`), record `pre_fix_object` via `autodev-guard snapshot` (preserves working tree & stash list).

### Review, Fix, Gate & Commit

1. **Diff scope:** run `autodev-guard diff-scope` against `{task_base}` (add `-PrevSha`/`--prev-sha` `{pre_fix_object}` on Review Iter 2+; fallback: `git diff --name-only {task_base}`, `git diff --cached --name-only`, `git ls-files --others --exclude-standard`), excluding `.b3/autodev/`, unchanged `initial_dirty_paths`, and noise. Never use `HEAD~1`.
2. **Risk-tiered Review:** `depth: inline` + `SMALL` diff (no auth/contract/schema/hot-path) → 1 `reviewer.md` pass (escalate to `review-loop` on blocking `CONFIRMED`). Else run [`../review-loop/strategy.md`](../review-loop/strategy.md) with active-only `findings.md` slices and compact replies (log hat-change limit in `{RUN_DIR}/progress.md` if unisolated).
3. **Gate & Commit:** require passing ACs, executed checks, 0 blocking `CONFIRMED` findings, diff in declared `files`/`tests`, no residue (`INCOMPLETE` on missing evidence; `incomplete`/`FAIL` on red check/defect; `blocked`/`BLOCKED` on overlapping `initial_dirty_paths` or user decision). Run `autodev-guard precommit`, commit once (no `--no-verify`, amend, reset, push, merge, deploy), record SHA + `completed`, collapse `T00N` approach, and **immediately** start the next ready task.

## Final verification & Outcomes

When all required tasks are `completed`:
1. Verify `AC1..ACn`, `Invariants`, full checks vs `baseline_status`, and confirm all `completed` commits are ancestors of `HEAD` (`git log --oneline {run_base_sha}..HEAD`).
2. Run cumulative `review-loop` on `{run_base_sha}..HEAD` (excluding unchanged `initial_dirty_paths`): if all tasks passed independent review, default to **Cross-Cutting mode** (`git diff --stat` + boundary/multi-task files, contracts, cross-task duplication). Final cross-task fixes get one commit under `final`.
3. Non-ignored dirty files added during the run block `PASS` (`INCOMPLETE`). Set `run_status` (`PASS` | `FAIL` | `INCOMPLETE` | `BLOCKED`) and report ACs, task SHAs, checks vs baseline, review result, remaining issues, unverified claims, and PR readiness.
