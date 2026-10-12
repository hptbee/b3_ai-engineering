# Autonomous development

One invocation carries a requirement or an existing plan through implementation, verification, independent review, and focused commits until the work is done or an explicit blocker stops it.

This file is the only autonomous-development procedure. Host entry points select it; they do not restate it. It sequences existing skills and the review loop. It does not replace their files.

```text
Understand → Analyze → Plan → Decompose
  → for each ready task:
      JIT plan → Readiness gate → Implement → Test → Review → Fix → Verify → Commit
  → Final verification
```

Inner product sequence: [`feature-implementation.md`](feature-implementation.md). Independent review: [`../review-loop/strategy.md`](../review-loop/strategy.md) and [`../review-loop/spec.md`](../review-loop/spec.md).

## When to use

- The user asks to take a story, requirement, plan, bug, or refactor through the full lifecycle without calling plan, implement, review, and verify separately.
- The user asks to resume or report an interrupted run.

## When not to use

- Plan only → `.cursor/commands/plan.md` and the planning skill. Stop after the plan.
- One implementation request → `.cursor/commands/implement.md`. Do not start this workflow.
- Diagnosis before a cause is known, as the whole task → `.cursor/commands/debug.md`.
- One review pass → `.cursor/commands/review.md`.
- Review-loop only → `.cursor/commands/review-loop.md`.
- A named verification claim with no implementation → `.cursor/commands/verify.md`.

The planning skill stops after the plan. Problem-solving stops or escalates at the end of its own loop. Invoking this workflow is an explicit request to continue through the lifecycle, which outranks those stops (`docs/precedence.md`). Inside this workflow only:

- Planning continues into execution.
- Problem-solving covers the task change and its checks. Skip its single review step and its final stop.
- [`feature-implementation.md`](feature-implementation.md) supplies understand, plan, implement, and verify. Its one-pass review does not run. The review loop below is the review.

## Host entry

| Host | How the user starts | What the agent opens |
| --- | --- | --- |
| Cursor | `/autodev` | `.cursor/commands/autodev.md`, then this file |
| Codex | Name the intent: autonomous development, `autodev`, `resume`, or `status` | Same command file, then this file |
| Claude Code | Same named intent. A local slash command may point here | Same command file, then this file |

Details and limits: [`../adapters/cursor/README.md`](../adapters/cursor/README.md), [`../adapters/codex/README.md`](../adapters/codex/README.md), [`../adapters/claude/README.md`](../adapters/claude/README.md). Product-repo attach: [`../adapters/install-product.ps1`](../adapters/install-product.ps1) / [`../adapters/install-product.sh`](../adapters/install-product.sh).

A terminated host session does not restart itself. The next session continues only when the user invokes this workflow again (`resume` or a new `/autodev` with no fresh requirement and an existing checkpoint).

## Locate B3 and the product root

This workflow may run inside the B3 system repository or inside a **separate product repository**.

`PRODUCT_ROOT` is the git root of the repository whose files will change.

`B3_HOME` is the B3 system repository. Resolve it in this order. Stop at the first match that contains `workflows/autonomous-development.md`:

1. This file's repository, if the current git root contains `workflows/autonomous-development.md`
2. Environment variable `B3_HOME`
3. `{PRODUCT_ROOT}/.b3/home` (one line, absolute path, written by the product installer)

If none match → `BLOCKED`. Ask the user to set `B3_HOME` or run the product installer. Do not invent a second procedure.

Load skills, rules, review-loop, commands, and agents from `B3_HOME`. Markdown links in this file are relative to `B3_HOME/workflows/`.

Write checkpoints and make Git commits in `PRODUCT_ROOT`. Do not copy `B3_HOME/.cursor/skills` into the product repository. Do not create product `.agents/skills` or `.claude/skills` while using Cursor in that product (duplicate discovery).

## State

Write checkpoints in `PRODUCT_ROOT`:

```text
.b3/autodev/
  master-plan.md
  progress.md
  findings.md
  approach/T00N.md    optional; notes and detailed depths only
```

`findings.md` is the only finding log for this run. Use the review-loop schema ([`../review-loop/spec.md`](../review-loop/spec.md), [`../review-loop/findings.md`](../review-loop/findings.md)). Do not also write `review-loop/state/current.yaml`. Do not invent a second lifecycle.

Create the file on the first review. Append one section per task or final pass. IDs (`R001`, `R002`, …) increment for the whole run and are never recycled or reset. Until the file exists, progress says no finding log yet.

Update checkpoints when the plan is accepted for execution, when a task starts, when a task commits or blocks, and at the final outcome.

### Checkpoint git policy

`.b3/` is local run state. It must not enter a task commit.

1. Ensure `{PRODUCT_ROOT}/.gitignore` contains a line `.b3/`. If it is missing, append that line. Do not remove other ignore rules. Do not rewrite the user's gitignore.
2. Never `git add .b3/`. Never `git add -A` or `git add .`.
3. Before every commit, run `git diff --cached --name-only`. If any path starts with `.b3/`, unstage those paths. If they cannot be unstaged without discarding user files → `BLOCKED`.
4. Ignored `.b3/` files do not make the worktree dirty for the final `PASS` check.
5. Other untracked or uncommitted product files block `PASS`. List them. Do not delete them.

Do not commit `.b3/autodev/` unless the user asks. Do not discard unrelated user files to make the tree clean.

This system repo ignores `.b3/` so a run here does not become source. Product repos get the same ignore line from the installer or from step 1.

## Input

1. `status` → read the checkpoint and Git. Report. Do not implement.
2. `resume`, or no new requirement while `.b3/autodev/progress.md` exists → Scenario C.
3. No new requirement and no checkpoint → stop. Ask what to build. Outcome `BLOCKED`.
4. A file or text that is already a plan → Scenario B. Normalize only what is missing.
5. A story, requirement, bug report, or refactor request → Scenario A.

A bug whose cause is unknown uses [`.cursor/skills/engineering/debugging/SKILL.md`](../.cursor/skills/engineering/debugging/SKILL.md) before any patch. A behavior-preserving restructure uses [`.cursor/skills/engineering/refactoring/SKILL.md`](../.cursor/skills/engineering/refactoring/SKILL.md).

## Scenario A — no plan

1. Restate the request, current behavior, and desired behavior.
2. Inspect the code that would be touched. Search for an existing implementation before proposing a new one.
3. Note architecture, dependencies, conventions, missing requirements, and assumptions.
4. Write `.b3/autodev/master-plan.md` with the planning skill ([`.cursor/skills/engineering/planning/SKILL.md`](../.cursor/skills/engineering/planning/SKILL.md)). Load [`.cursor/skills/architecture/simplest-correct/SKILL.md`](../.cursor/skills/architecture/simplest-correct/SKILL.md) when the plan chooses system shape.
5. Check that every original requirement has a task or an explicit exclusion, that task ids are stable, and that each task names its verification.
6. Continue at [Execution](#execution). Do not stop for approval of ordinary technical choices.

Stop as `BLOCKED` only for a genuine business ambiguity, a scope change, or a high-risk operation that needs authorization (push, merge, deploy, destructive git, secrets, production data).

## Scenario B — existing plan

1. Read the supplied plan. Keep its requirements and intent.
2. Check structure, dependencies, scope, and acceptance criteria against the plan contract below.
3. Compare tasks with the codebase and Git. Mark a task `completed` only when the code and a recorded commit or an equivalent already-landed change support it.
4. Add missing ids, dependencies, or acceptance criteria. Delete a task only when it is obsolete, and record why under Plan changes.
5. The checkpoint copy is `.b3/autodev/master-plan.md`. If the supplied plan is already that file and matches this contract, leave the tasks as written. If it lives elsewhere, copy it once. Do not rewrite tasks that already match the contract.
6. Continue at [Execution](#execution).

## Scenario C — interrupted run

1. Read `.b3/autodev/master-plan.md`, `progress.md`, `findings.md` if it exists, and `approach/*.md` if they exist. Approach notes are decisions, not a second master plan.
2. Resolve `B3_HOME` and `PRODUCT_ROOT`. If `progress.md` records `b3_home` or `plan_id` and they do not match the current plan file and B3 location → `BLOCKED`.
3. Read branch, `HEAD`, ancestry, and `git status --porcelain`. Progress files are claims, not proof.
4. If progress records `branch` and the current branch differs → `BLOCKED`. Do not continue on the wrong branch.
5. Treat a task as `completed` only when **all** of these hold:
   - The recorded commit SHA exists (`git cat-file -t <sha>` is `commit`)
   - It is an ancestor of `HEAD` (`git merge-base --is-ancestor <sha> HEAD`)
   - It is unique among completed task SHAs in this run
   - It is a descendant of that task's `task_base` (or of `run_base_sha` if `task_base` was not recorded)
   - The commit's tree still supports the task acceptance criteria, or those checks are re-run and pass
6. SHA existence alone is not completion. A SHA on another branch, rewritten off `HEAD`, or reused for two tasks is not completion. Inspect the tree before doing the work again.
7. If the current task has uncommitted changes → inspect them. Keep valid work. Do not reset, and do not start a second copy of the same change.
8. Re-run the quality gate for an `in_progress` task before trusting it.
9. If that task already has a readiness record of `ready` and named files still exist at `task_base` / current tree, reuse the approach. Re-run [Analyze](#analyze) only when the record is missing, files vanished, or HEAD is not a descendant of `task_base`. Do not write a new master plan.
10. Resume the lowest-id `in_progress` task whose dependencies are `completed`. If none, take the lowest-id ready `pending` task. Leave `blocked` tasks blocked until the recorded blocker is resolved. If Analyze had passed the gate and implementation had not started, **continue into Implement** in this session. Do not wait for a new user command.

Do not repeat a task that meets the completion tests above. Do not create a second commit for the same completed task.

## Plan contract

`.b3/autodev/master-plan.md`:

```markdown
# <objective>

- version: 1
- source: <user text or path>

## Original requirements
## Scope
## Exclusions
## Technical context
## Architecture
## Assumptions
## Risks

## Tasks

### T001 — <title>

- status: pending
- depends_on: []
- scope: <paths or components>
- acceptance_criteria:
  - <observable behavior>
- verification:
  - <command or probe>

## Completion criteria
## Plan changes
```

Task fields:

| Field | Rule |
| --- | --- |
| `id` | Stable. `T001`, `T002`, … Never reuse an id for different work |
| `status` | `pending`, `in_progress`, `completed`, `blocked`, `incomplete` |
| `depends_on` | Task ids that must be `completed` first. `[]` if none |
| `scope` | What this task may change |
| `acceptance_criteria` | Behavior, not a restatement of the patch |
| `verification` | The check that would show the criterion holds |

Size: one independently verifiable change that can be one commit. A trivial edit is one task. A large feature is several tasks, not one unreviewable task, and not a swarm of one-line tasks.

`version` increments when tasks, criteria, or scope change. Record each change under Plan changes with the reason. Technical refinement that still meets the original requirement does not need approval. Dropping a requirement, changing business behavior, or widening scope is `BLOCKED` until the user decides. Do not edit acceptance criteria so an incomplete implementation looks finished.

## Execution

On first start of a run, record in `progress.md` before changing files:

- `b3_home`, `product_root`
- `plan_id` (title + version from the master plan)
- `plan_version`
- `branch` (`git branch --show-current`)
- `run_base_sha` (`git rev-parse HEAD`)

If `run_base_sha` is missing on resume, reconstruct it only from Git evidence (the parent of the first recorded task commit, or current `HEAD` if no task commits exist). If it cannot be reconstructed → `INCOMPLETE`.

Ready work: `pending`, every `depends_on` id is `completed`. Run ready tasks one at a time, lowest id first. If a task ends `blocked`, `incomplete`, or failed, do not start tasks that depend on it. Stop the run after reporting. Leave independent later tasks `pending`.

When a task starts, set `current_task_base_sha` to `git rev-parse HEAD` and write it on that task as `task_base`. Then run [Analyze](#analyze). Do not open product files for editing until the Implementation Readiness Gate passes.

For the selected task, load that task, the files it names, and the smallest domain skill. Follow imports, callers, and contracts the inspect step names. Use progress and existing approach notes as the handoff. Do not reread the whole repository. Do not write a second master plan.

### Analyze

Just-in-Time planning for **this** ready task. Scenario A/B already wrote the one master plan; do not decompose again. Do **not** load the planning skill here (it stops after a multi-task plan). Follow [`.cursor/skills/engineering/problem-solving/SKILL.md`](../.cursor/skills/engineering/problem-solving/SKILL.md) Understand/Plan for this slice. Load [`.cursor/skills/architecture/simplest-correct/SKILL.md`](../.cursor/skills/architecture/simplest-correct/SKILL.md) only if the approach would add a layer, service, or public-contract shape. Then apply the gate and continue into Implement. Do not wait for the user.

1. Restate current behavior, desired behavior, and constraints from **inspected code**, not from master-plan prose alone.
2. Inspect the named scope plus callers, callees, types/DTOs, routes, schema, fixtures, and existing tests. Reuse what exists. Do not guess a file list.
3. Record `contracts` (HTTP, signatures, events, stored data) or `contracts: none`. Sketch who reads/writes the slice. List material edge cases, or `edge_cases: none material` with a one-line reason. An obvious neighbor-code boundary (empty input, unauthorized caller, missing row, compatibility) that is omitted fails the gate.
4. Choose **persistence depth** (not the later review-loop size of the diff):
   | Depth | Use when | Persist |
   | --- | --- | --- |
   | **inline** | One area, few files, no public contract, schema, auth, or migration | `progress.md` → `## Approach` → `### T00N` only. No `approach/` file. |
   | **notes** | More files, two areas, or a local contract inside one module | `.b3/autodev/approach/T00N.md` and the same `### T00N` heading with `depth` + `readiness` |
   | **detailed** | Public API or schema, auth, migration, production data, or a new layer/service | Same approach file, complete enough to resume without the old chat. Apply `simplest-correct` to the approach. Do **not** dispatch `architecture-reviewer` yet (no product diff). That agent runs in Review after code exists. |
   When unsure inline vs notes, use notes.
5. Write the approach: files and functions, required changes, tests ([`.cursor/skills/engineering/testing-strategy/SKILL.md`](../.cursor/skills/engineering/testing-strategy/SKILL.md)), verification. Smallest change that meets the task. The master plan is a hypothesis; the code wins when they disagree. Record a master-plan correction under Plan changes when the task itself changes. Do not add extra tasks for this slice.
6. **Implementation Readiness Gate.** Do not edit product files until inspection evidence, contracts/data-flow/edges, named files/changes/tests/verification, and persistence depth are recorded. Incomplete inspection → task `incomplete`, run `INCOMPLETE`. Business choice or authorization → task `blocked`, run `BLOCKED`. Ordinary technical choices are not `BLOCKED`.
7. Gate pass → **immediately** Implement in this session. Do not ask the user to approve the approach or to run `/implement`.

`notes` / `detailed` approach file (gitignored with `.b3/autodev/`):

```markdown
# T00N approach

- depth: notes
- readiness: ready

## Inspected
## Current / desired
## Files and functions
## Contracts
## Data flow
## Edge cases
## Changes
## Tests
## Verification
## Architecture
```

### Implement

Follow [`.cursor/skills/engineering/problem-solving/SKILL.md`](../.cursor/skills/engineering/problem-solving/SKILL.md) for the change: smallest correct diff, existing architecture, no drive-by refactor, no speculative features. Preserve compatibility when the requirement says so. Execute the readiness approach; do not rewrite it as a second plan. If the code disagrees, update the approach (and master-plan Plan changes when the task changes), then continue. Skip that skill's single review step. The task review is the review loop below.

### Test

Choose checks with [`.cursor/skills/engineering/testing-strategy/SKILL.md`](../.cursor/skills/engineering/testing-strategy/SKILL.md). Run the checks the task named, plus lint, typecheck, or build when the repo already uses them for this area. Add tests that would fail if the behavior were wrong. Do not weaken or delete a test to get a green result. Judge evidence with [`.cursor/skills/engineering/verification/SKILL.md`](../.cursor/skills/engineering/verification/SKILL.md) and [`../rules/verification.md`](../rules/verification.md).

### Review

Name the review target before dispatching. The range is `{task_base}..HEAD` plus the working tree.

Collect **all** of:

```text
git diff --name-only {task_base}
git diff --cached --name-only
git ls-files --others --exclude-standard
git status --porcelain
```

The task diff is staged + unstaged + new untracked files, excluding ignored `.b3/` paths. An unstaged or untracked file that belongs to the task is in scope. `git diff HEAD` alone is not enough if the task created untracked files.

Pass that file list and `{task_base}` to [`../review-loop/strategy.md`](../review-loop/strategy.md). Size with [`../review-loop/sizing.md`](../review-loop/sizing.md). Do not let the reviewer substitute `HEAD~1` or a PR base from another branch.

Cover correctness, security, architecture, performance, reliability, maintainability, tests, requirement fit, unnecessary complexity, duplication, dead code, obsolete fallbacks, and residue from earlier fixes. Those dimensions already live in the review-loop spec. Do not open a second review method.

Dispatch reviewer and fixer roles when the host can isolate them (`.cursor/agents/`). The reviewer does not edit. The fixer does not declare `PASS`. If isolation is unavailable, hat-change as `review-loop/strategy.md` describes and write that limit in `progress.md`. Hat-change is not independent review.

### Fix

Validate each finding. Fix `CONFIRMED` issues with the fixer role. Re-run the verification that would have caught the issue. Fresh review of the current diff. Caps, stagnation, and speculative-versus-confirmed rules stay in the review-loop spec. Stop when the loop says gate, stuck, or limit. Do not keep cycling past that.

### Quality gate

Commit only when all of these are true:

- Acceptance criteria hold.
- Named checks ran and passed.
- No blocking `CONFIRMED` finding remains.
- The diff stays inside the task scope.
- Product files in the diff are named in the approach (or tests named under verification). If the code forced extra files, the approach was updated with the reason **before** this gate. Unexplained extra files fail the gate.
- No unrelated user changes are staged.
- No confirmed residue remains.
- The task's checks were run and the results are recorded.

Missing evidence is `INCOMPLETE`, not `PASS`. A failed check is `FAIL`. Do not commit that task as `completed`.

### Commit

One commit for the task that passed the gate.

- Stage only files that belong to the task.
- Do not stage `.b3/`. Confirm with `git diff --cached --name-only`.
- Follow the repository's commit message style.
- Message says why, in a sentence or two.
- Record the full SHA in `progress.md` and set the task to `completed`.
- Do not use `--no-verify` unless the user explicitly asked.
- Do not amend, reset, force-push, or discard unrelated work.
- Do not push, merge, or deploy.

If the gate failed, there is no completion commit. Use one status:

| Situation | Task | Run |
| --- | --- | --- |
| A named check failed | `incomplete` | `FAIL` |
| Evidence missing, or the review loop stopped at its cap or stagnation rule and no confirmed defect remains | `incomplete` | `INCOMPLETE` |
| A confirmed defect remains after the review loop stops | `incomplete` | `FAIL` |
| The user must decide or authorize the next step | `blocked` | `BLOCKED` |
| Unrelated user edits overlap files this task must change | `blocked` | `BLOCKED` |

Do not label a failed check or a review-loop cap as `BLOCKED`. Leave unrelated non-overlapping edits unstaged. Do not discard them.

### Continue

After a completion commit, write the handoff in `progress.md`: task id, SHA, checks and results, review outcome, next ready task. **Immediately** start the next ready task in the **same session**. Do not ask the user to invoke `/implement`, `/plan`, or `/autodev resume` while `run_status` is `running` and a ready `pending` task exists.

Repeat the task loop (JIT plan → readiness gate → implement → test → review → fix → quality gate → commit → continue) until every required task is `completed`, `run_status` is `BLOCKED` / `FAIL` / `INCOMPLETE`, or final verification finishes with `PASS`. A plan note or an older user message that says “only the first task” or “stop after one task” does **not** override this workflow unless the **current** user message repeats that limit for **this** invocation. Do not stop after a passing readiness gate to wait for `/implement`.

Do not end the turn with “next: run `/autodev resume`” when ready work remains and nothing is `BLOCKED`.

## Progress

`.b3/autodev/progress.md`:

```markdown
# Progress

- b3_home: <absolute path>
- product_root: <absolute path>
- plan_id: <title + version>
- plan_version: 1
- branch: <branch>
- run_base_sha: <full SHA at run start>
- current_task: T001
- current_task_base_sha: <full SHA when T001 started>
- run_status: running
- updated: <ISO-8601>

## Tasks

| id | status | task_base | commit | verification | review | depth | readiness |
| --- | --- | --- | --- | --- | --- | --- | --- |
| T001 | in_progress |  |  |  |  |  |  |

## Approach

### T001
- depth: inline
- readiness: ready
- files:
- contracts: none
- edge_cases:
- tests:
- verification:

## Blockers
## Next action
## Limitations
```

`run_status` while work remains is `running`. The final value is the outcome: `PASS`, `FAIL`, `INCOMPLETE`, or `BLOCKED`.

## Final verification

When every required task is `completed`, the feature is still not done until this pass finishes:

1. Re-read the original requirements.
2. Check every acceptance criterion.
3. Check integration across tasks.
4. Run the regression, build, and type checks the repo uses for this change.
5. Review the cumulative range `{run_base_sha}..HEAD` plus any remaining uncommitted product files, using the review loop. Include every commit in `git log --oneline {run_base_sha}..HEAD`. Large diffs use that loop's adaptive sizing, including its cross-cutting pass. Findings still go to `.b3/autodev/findings.md`.
6. Look for duplication introduced across tasks.
7. Check that architecture still matches the plan.
8. Confirm no required task was skipped.
9. Confirm each `completed` task commit exists, is an ancestor of `HEAD`, and appears in that log.

If that pass edits the tree, those edits are one final commit, not a new feature task. Its scope is the cross-task fix. The task-scope rule does not block it. The other gate rules still apply: checks passed, no blocking confirmed finding, no unrelated files, and evidence recorded. Record the SHA in progress under `final`. A dirty tree of **non-ignored** files, or a fix with no commit, is `INCOMPLETE`. Ignored `.b3/` files do not block `PASS`. Do not report `PASS` while non-ignored paths differ from the recorded commits.

Then set `run_status` and report:

- Requirements implemented
- Tasks and SHAs
- Checks executed and results
- Review result
- Remaining issues
- Claims that were not verified
- Whether the branch is ready for a pull request

Do not open the pull request, push, or merge unless the user asks.

## Outcomes

| Outcome | Use when |
| --- | --- |
| `PASS` | Requirements hold, gates passed, commits exist, and final verification evidence supports completion |
| `FAIL` | A required check or confirmed defect shows the work is wrong |
| `INCOMPLETE` | Work or evidence is missing, the Implementation Readiness Gate failed for lack of inspection, a tool did not run, or the review loop hit its limit or stagnation rule |
| `BLOCKED` | The run needs a user decision or authorization |

`PASS` means the evidence holds, not that the checklist was ticked. A review-loop `UNKNOWN / INCOMPLETE` stays that loop's outcome and the run is `INCOMPLETE`. A remaining confirmed defect is `FAIL`. `BLOCKED` is only a user decision or authorization, including an overlapping unrelated edit.

## Context

At each task boundary the handoff in `progress.md` (and `approach/T00N.md` when that class requires it) is the memory. The next session must be able to continue from the files and Git without the old conversation. Do not put task-level approaches in `master-plan.md`.

Use a subagent for isolated review or fix. Do not spawn agents for a trivial edit or to look busy.

## What this is not

No orchestration service, workflow runner, agent SDK, queue, scheduler, database, or extra review framework. The coding agent in the active session is the orchestrator. Terminal and Git are the host's existing tools.
