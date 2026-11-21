# Autonomous development

One invocation carries a requirement or an existing plan through planning, implementation, verification, independent review, and focused commits until completion or an explicit blocker. This is the single autonomous procedure; host entry points select it and do not duplicate it.

```text
Understand & Pre-flight → Plan (master-plan)
  → for each ready task:
      JIT Analyze → Readiness Gate → [Pre-code Risk Review] → Implement → Test
      → Pre-fix Snapshot → Review → Fix → Verify → Pre-commit Guard → Commit
  → Final verification
```

Inner steps: [`feature-implementation.md`](feature-implementation.md). Independent review: [`../review-loop/strategy.md`](../review-loop/strategy.md), [`../review-loop/spec.md`](../review-loop/spec.md), [`../review-loop/sizing.md`](../review-loop/sizing.md). Checkpoints & schemas: [`references/autodev-templates.md`](references/autodev-templates.md). Resume reconciliation: [`references/autodev-resume.md`](references/autodev-resume.md). Deterministic CLI guard: `scripts/autodev-guard.ps1` / `scripts/autodev-guard.sh` (helper only — never a runner).

## When to use / not use

- **Use:** end-to-end story, requirement, plan, bug, or refactor lifecycle; `resume` or `status` on `.b3/autodev/`.
- **Do not use:** plan-only (`commands/plan.md`), single implement (`commands/implement.md`), root-cause debug only (`debug.md`), one-pass review (`review.md`), review-loop only (`review-loop.md`), or claim verification only (`verify.md`).
- **Precedence inside `/autodev`:** explicit invocation overrides `planning` and `problem-solving` stops (`docs/precedence.md`); skip `problem-solving`'s single review and final stop because this workflow governs task review and continuation.

## Host entry & B3 resolution

| Host | Start | Entry |
| --- | --- | --- |
| Cursor | `/autodev` | `commands/autodev.md` (via `.cursor/commands` link or product `.cursor/commands/autodev.md`), then this file |
| Codex | `autodev`, `$autodev`, `resume`, or `status` | `adapters/command-skills/autodev/SKILL.md` → `commands/autodev.md`, then this file |
| Claude Code | `/autodev`, `autodev`, `resume`, or `status` | `adapters/command-skills/autodev/SKILL.md` (via `.claude/skills/autodev`) → `commands/autodev.md`, then this file |
| Antigravity | `/autodev` or `autodev` skill | `adapters/command-skills/autodev/SKILL.md` (via `.agents/skills.json` / plugin) → `commands/autodev.md`, then this file |

Host details: [`../adapters/cursor/README.md`](../adapters/cursor/README.md), [`../adapters/codex/README.md`](../adapters/codex/README.md), [`../adapters/antigravity/README.md`](../adapters/antigravity/README.md), [`../adapters/claude/README.md`](../adapters/claude/README.md). A stopped session resumes only when the user re-invokes `/autodev` (`resume`).

Resolve `PRODUCT_ROOT` (git root under change) and `B3_HOME` (first containing `workflows/autonomous-development.md`: this repo if matching, `$env:B3_HOME` / `$B3_HOME`, or `{PRODUCT_ROOT}/.b3/home`; else `BLOCKED`). Load skills/rules/agents from `B3_HOME`. Write checkpoints and commits in `PRODUCT_ROOT`. Never copy `skills/` into `PRODUCT_ROOT`.

## State & checkpoint git policy

Checkpoints live at `{PRODUCT_ROOT}/.b3/autodev/` (`master-plan.md`, `progress.md`, `findings.md`, optional `approach/T00N.md`). Update `progress.md` at plan acceptance, task start, pre-fix snapshot, commit/block, and final outcome. `findings.md` is the sole finding log (`R001`, `R002`, … monotonic; never write `review-loop/state/current.yaml`).

1. In product repos, ensure `{PRODUCT_ROOT}/.gitignore` ignores `.b3/autodev/` (upgrading bare `.b3/` if needed so `.b3/home` can commit). This system repo keeps `.b3/` ignored.
2. Never `git add .b3/autodev/`, `git add -A`, or `git add .`.
3. Before every commit, check `scripts/autodev-guard.{ps1,sh} precommit` or `git diff --cached --name-only`; unstage any checkpoint paths (`BLOCKED` if impossible without discarding user edits).
4. Ignored `.b3/` files never make the tree dirty. Remaining untracked/uncommitted files created during the run block `PASS` (list them; never delete them).

## Input & Pre-flight

1. `status` → read `.b3/autodev/` and Git; report without editing.
2. `resume`, or no new requirement while `.b3/autodev/progress.md` exists → **Scenario C** ([`references/autodev-resume.md`](references/autodev-resume.md)).
3. No requirement and no checkpoint → ask what to build; stop `BLOCKED`.
4. Existing plan → **Scenario B**; requirement/story/bug/refactor → **Scenario A** (`debugging` skill first for unknown bug cause; `refactoring` skill for behavior-preserving restructure).

### Scenario A / B (Master plan & pre-flight)

1. Restate request, current behavior, and desired behavior from inspected code (never invent implementations over existing helpers).
2. **Pre-flight discovery:** Record `initial_dirty_paths` (current modified/untracked non-ignored paths) and locate canonical `build`/`typecheck`/`lint`/`test` commands from CI workflows, git hooks, or build manifests (respecting repo linter config per `docs/precedence.md`; never impose extra lint rules). Run the baseline check at `run_base_sha` (in background while planning or before `T001`) and record `baseline_status` in `progress.md` so pre-existing red checks are never misattributed to `T00N`.
3. Write or normalize `.b3/autodev/master-plan.md` per [`references/autodev-templates.md`](references/autodev-templates.md) using [`skills/engineering/planning/SKILL.md`](../skills/engineering/planning/SKILL.md) (plus `simplest-correct` for system shape):
   - Include 3–5 cross-task `Invariants` and numbered `AC1..ACn` criteria per task.
   - **Contract-first & Shared Hotspots:** Assign shared hotspot files (`package.json`, `.csproj`, barrel `index.ts`, migrations, shared types/contracts) to **one** foundational task committed before dependent tasks read those committed files from disk.
   - **Size & Split check:** Estimate total scope against [`../review-loop/sizing.md`](../review-loop/sizing.md). If `> ~800 lines` or `>= 2 independent areas`, record a 1-line PR split warning in `master-plan.md` without pausing cohesive features.
   - Scenario B: keep supplied requirements/intent; mark tasks `completed` only if Git/code proves them; copy external plan once to `.b3/autodev/master-plan.md` (leave matching plans intact).
4. Proceed directly into **Execution** without waiting for user approval. Stop as `BLOCKED` only for genuine business ambiguity, overlapping `initial_dirty_paths`, external authorization (push, merge, deploy, destructive git, secrets, prod data), or **unrequested destructive/breaking changes** (data-loss column drop/rename, weakening existing authz, breaking existing public API contracts). Ordinary `>= 4`-task plans or routine `auth`/`migration`/`shared` changes stay autonomous (`depth: detailed`).

## Execution

On run start, record in `progress.md`: `b3_home`, `product_root`, `plan_id` (title + version), `plan_version`, `branch`, `run_base_sha`, `baseline_status`, and `initial_dirty_paths`. (If missing on resume, reconstruct `run_base_sha` only from Git history, else `INCOMPLETE`.)

Run ready tasks (`pending`, all `depends_on` `completed`) one at a time, lowest id first. When a task starts, record `task_base` = `git rev-parse HEAD` and run **Analyze**. Never edit product files until the **Implementation Readiness Gate** passes.

### Analyze (Just-in-Time planning)

Do **not** load the planning skill here or write a second master plan. Follow [`../skills/engineering/problem-solving/SKILL.md`](../skills/engineering/problem-solving/SKILL.md) Understand/Plan for this slice:

1. Inspect named scope, callers, callees, DTOs/types, routes, schema, fixtures, and existing tests. Restate current/desired behavior from inspected code.
2. Separate writable **`files`** (owned) from **`read_only_deps`** (inspected contracts/schemas/callers that this task reads but must not edit); **`watched_paths`** = `files` + `read_only_deps` (real repo paths only, never logical names).
3. Record **`reuse:`** (canonical helpers/hooks/components/DTOs to reuse) and **`obsoletes:`** (dead paths/fallbacks this slice will remove, or `none`).
4. Choose **persistence depth** (`inline` in `progress.md` for small single-area edits; `notes` in `approach/T00N.md` for multi-file/two-area/local-contract work; `detailed` in `approach/T00N.md` for public API/schema/auth/migration/prod data/new layer or `>= 4`-task cross-cutting contracts). When unsure inline vs notes, use `notes`.
5. **Conditional risk fields (`detailed` depth):** Populate `write_paths:` (multi-store writes + cache invalidation) when persisting/caching an entity in `>= 2` stores; `io_budget:` when touching query/list APIs or render loops; and concrete crash/retry/timeout/double-submit/auth outcomes in `edge_cases:`.
6. **Evidence-based refinement:** If inspection proves one task cannot be one independently verifiable commit: keep the original id for the first slice; add remaining slices at the next unused `T00N` ids; chain `depends_on` and retarget existing dependents; bump master-plan `version` + `progress.md` `plan_id`/`plan_version` + approach `plan_version`, logging evidence under `Plan changes`. Continue Analyze without pausing.
7. **Implementation Readiness Gate:** Templates start at `readiness: draft`; empty template headings are not evidence. Set `readiness: ready` only when `inspected`, `files` (or explicit new-file intent), `watched_paths`, `reuse`, `obsoletes`, `changes`, `verification`, and `task_spec_fingerprint` are non-empty (`data_flow` may be `n/a` with reason). Compute `task_spec_fingerprint` via `scripts/autodev-guard.{ps1,sh} fingerprint` (`depends_on=<sorted comma ids or []>|scope=<trimmed>|acceptance_criteria=<criteria joined with ; >`), record `approach_at_sha` (`git rev-parse HEAD`), and fail `INCOMPLETE` if inspection was incomplete.
8. **1-Pass Pre-code Risk Review (`detailed` depth only — no Debate Round):** If host isolation exists and approach sections are non-empty, dispatch `architecture-reviewer.md` with **`design-only`** and the approach path; also dispatch `security-reviewer.md` (`design-only`) when auth, untrusted input, concurrency/race, or abuse surface applies. Never name a product diff. Empty approach → do not dispatch. On any `CONFIRMED` flaw, revise the approach, reset `readiness: draft`, and **re-run the Implementation Readiness Gate (step 7)** before coding. Gate pass → proceed immediately to `Implement`.

### Implement, Test & Pre-fix Snapshot

- **Context isolation (`Subagent-per-task`):** On runs with `>= 3` tasks and a `notes`/`detailed` slice where the host supports write-capable subagents, parent may stay thin orchestrator and delegate `Implement + Test` of `T00N` to a clean subagent bounded by `files`, `read_only_deps`, `reuse`, and `obsoletes`; parent retains gates, review dispatch, and commits.
- **Implement:** Execute the `ready` approach (`problem-solving` + smallest domain skill) with minimal changes; delete confirmed `obsoletes`; update approach + `Plan changes` if inspected reality forces extra files.
- **Test:** Choose checks with `testing-strategy`; run task checks plus repo canonical checks, accounting for `baseline_status`; evaluate strictly with `verification` (`rules/verification.md`).
- **Pre-fix Snapshot:** Once `Implement + Test` is green (and before entering `Fix`), capture `pre_fix_object` via `scripts/autodev-guard.{ps1,sh} snapshot` (`git stash create`, falling back to `HEAD` when tracked files are clean) in `progress.md` without modifying the working tree or stash list.

### Review, Fix, Gate & Commit

1. **Collect task diff (`{task_base}..HEAD` + working tree):** Run `git diff --name-only {task_base}`, `git diff --cached --name-only`, `git ls-files --others --exclude-standard`, `git status --porcelain`. Exclude `.b3/autodev/` and unchanged `initial_dirty_paths`. Never substitute `HEAD~1`.
2. **Risk-tiered Review:**
   - **`depth: inline` + `SMALL` diff** (no auth, public contract, schema, or hot-path surface): dispatch 1 independent `reviewer.md` pass (`review-loop` dimensions including residue check); escalate to full `review-loop` only if a blocking `CONFIRMED` finding exists.
   - **`depth: notes` / `detailed` (or escalated `inline`):** run full [`../review-loop/strategy.md`](../review-loop/strategy.md) (`reviewer`, `fixer`, and specialist reviewers when routed). Record hat-change limit in `progress.md` if host isolation is unavailable.
3. **Quality gate:** Commit only when all `AC` hold, named checks passed, blocking `CONFIRMED` findings = 0, diff stays in declared `files`/`tests` (approach updated first if expanded), no unrelated edits are staged, and no confirmed residue remains. Missing evidence → `INCOMPLETE`; failed check or remaining confirmed defect → `incomplete` / `FAIL`; overlapping `initial_dirty_paths` or user decision → `blocked` / `BLOCKED`. Never mark failed checks or loop caps as `BLOCKED`.
4. **Commit & Continue:** Verify staging via `scripts/autodev-guard.{ps1,sh} precommit`, commit one task commit (no `--no-verify`, amend, reset, push, merge, or deploy), record SHA + `completed` in `progress.md`, and **immediately** start the next ready task in the same session without prompting `/autodev resume`.

## Final verification & Outcomes

When every required task is `completed`:
1. Re-read original requirements, check all `AC1..ACn` and `Invariants`, verify cross-task integration, and run full repo regression/build/typecheck against `baseline_status`.
2. Run cumulative `review-loop` (`strategy.md` + `sizing.md`) on `{run_base_sha}..HEAD` plus any non-ignored uncommitted files (excluding unchanged `initial_dirty_paths`), checking cross-task duplication and plan alignment. Confirm every `completed` commit is an ancestor of `HEAD` in `git log --oneline {run_base_sha}..HEAD`. Any final cross-task fix produces one final commit recorded under `final`.
3. Non-ignored dirty files added during the run or un-committed fixes block `PASS` (`INCOMPLETE`). Set `run_status` (`PASS` | `FAIL` | `INCOMPLETE` | `BLOCKED`) and report: requirements/ACs, task SHAs, checks vs baseline, review result, remaining issues, unverified claims, and PR readiness.

*This workflow uses the active session as orchestrator and Git/terminal as runtime — no orchestration server, queue, or agent SDK.*
