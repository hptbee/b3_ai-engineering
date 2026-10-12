# Autonomous development

One invocation carries a requirement or an existing plan through implementation, verification, independent review, and focused commits until the work is done or an explicit blocker stops it.

This file is the only autonomous-development procedure. Host entry points select it; they do not restate it. It sequences existing skills and the review loop. It does not replace their files.

```text
Understand → Analyze → Plan → Decompose
  → for each ready task: Implement → Test → Review → Fix → Verify → Commit
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

Details and limits: [`../adapters/cursor/README.md`](../adapters/cursor/README.md), [`../adapters/codex/README.md`](../adapters/codex/README.md), [`../adapters/claude/README.md`](../adapters/claude/README.md).

A terminated host session does not restart itself. The next session continues only when the user invokes this workflow again (`resume` or a new `/autodev` with no fresh requirement and an existing checkpoint).

## State

Write checkpoints in the **repository under change**:

```text
.b3/autodev/
  master-plan.md
  progress.md
  findings.md
```

`findings.md` is the only finding log for this run. Use the review-loop schema ([`../review-loop/spec.md`](../review-loop/spec.md), [`../review-loop/findings.md`](../review-loop/findings.md)). Do not also write `review-loop/state/current.yaml`. Do not invent a second lifecycle.

Create the file on the first review. Append one section per task or final pass. IDs (`R001`, `R002`, …) increment for the whole run and are never recycled or reset. Until the file exists, progress says no finding log yet.

Update checkpoints when the plan is accepted for execution, when a task starts, when a task commits or blocks, and at the final outcome. Do not commit `.b3/autodev/` unless the user asks. Do not discard unrelated user files to make the tree clean.

This system repo ignores `.b3/` so a run here does not become source.

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

1. Read `.b3/autodev/master-plan.md`, `progress.md`, and `findings.md` if it exists.
2. Read branch, `HEAD`, task commits, and `git status`. Progress files are claims, not proof.
3. If progress says a task is `completed` but the recorded commit is missing → treat that task as not complete. Inspect the tree before doing the work again.
4. If the current task has uncommitted changes → inspect them. Keep valid work. Do not reset, and do not start a second copy of the same change.
5. Re-run the quality gate for an in-progress task before trusting it.
6. Resume the lowest-id `in_progress` task whose dependencies are `completed`. If none, take the lowest-id ready `pending` task. Leave `blocked` tasks blocked until the recorded blocker is resolved.

Do not repeat a task whose commit is present and whose acceptance checks still hold. Do not create a second commit for the same completed task.

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

Ready work: `pending`, every `depends_on` id is `completed`. Run ready tasks one at a time, lowest id first. If a task ends `blocked`, `incomplete`, or failed, do not start tasks that depend on it. Stop the run after reporting. Leave independent later tasks `pending`.

For the selected task, load only that task, the files it names, and the smallest domain skill. Use progress as the handoff from the previous task. Do not reread the whole repository.

### Analyze

Read the task. Inspect the code. Reuse what exists. Name the domain skill, the tests to add or update, and likely breakage. The plan is a hypothesis; the code wins when they disagree. Record a plan correction when that changes the task.

### Implement

Follow [`.cursor/skills/engineering/problem-solving/SKILL.md`](../.cursor/skills/engineering/problem-solving/SKILL.md) for the change: smallest correct diff, existing architecture, no drive-by refactor, no speculative features. Preserve compatibility when the requirement says so. Skip that skill's single review step. The task review is the review loop below.

### Test

Choose checks with [`.cursor/skills/engineering/testing-strategy/SKILL.md`](../.cursor/skills/engineering/testing-strategy/SKILL.md). Run the checks the task named, plus lint, typecheck, or build when the repo already uses them for this area. Add tests that would fail if the behavior were wrong. Do not weaken or delete a test to get a green result. Judge evidence with [`.cursor/skills/engineering/verification/SKILL.md`](../.cursor/skills/engineering/verification/SKILL.md) and [`../rules/verification.md`](../rules/verification.md).

### Review

Run [`../review-loop/strategy.md`](../review-loop/strategy.md) on **this task's diff**. Size with [`../review-loop/sizing.md`](../review-loop/sizing.md).

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
- No unrelated user changes are staged.
- No confirmed residue remains.
- The task's checks were run and the results are recorded.

Missing evidence is `INCOMPLETE`, not `PASS`. A failed check is `FAIL`. Do not commit that task as `completed`.

### Commit

One commit for the task that passed the gate.

- Stage only files that belong to the task.
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

After a completion commit, write the handoff in `progress.md`: task id, SHA, checks and results, review outcome, next ready task. Start that task. Do not ask the user to invoke the next stage.

## Progress

`.b3/autodev/progress.md`:

```markdown
# Progress

- plan_version: 1
- run_status: running
- current_task: T001
- updated: <ISO-8601>

## Tasks

| id | status | commit | verification | review |
| --- | --- | --- | --- | --- |
| T001 | in_progress |  |  |  |

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
5. Review the cumulative diff with the review loop. Large diffs use that loop's adaptive sizing, including its cross-cutting pass. Findings still go to `.b3/autodev/findings.md`.
6. Look for duplication introduced across tasks.
7. Check that architecture still matches the plan.
8. Confirm no required task was skipped.
9. Confirm each `completed` task has a commit that exists.

If that pass edits the tree, those edits are one final commit, not a new feature task. Its scope is the cross-task fix. The task-scope rule does not block it. The other gate rules still apply: checks passed, no blocking confirmed finding, no unrelated files, and evidence recorded. Record the SHA in progress under `final`. A dirty tree, or a fix with no commit, is `INCOMPLETE`. Do not report `PASS` while the worktree differs from the recorded commits.

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
| `INCOMPLETE` | Work or evidence is missing, a tool did not run, or the review loop hit its limit or stagnation rule |
| `BLOCKED` | The run needs a user decision or authorization |

`PASS` means the evidence holds, not that the checklist was ticked. A review-loop `UNKNOWN / INCOMPLETE` stays that loop's outcome and the run is `INCOMPLETE`. A remaining confirmed defect is `FAIL`. `BLOCKED` is only a user decision or authorization, including an overlapping unrelated edit.

## Context

At each task boundary the handoff in `progress.md` is the memory. The next session must be able to continue from the files and Git without the old conversation.

Use a subagent for isolated review or fix. Do not spawn agents for a trivial edit or to look busy.

## What this is not

No orchestration service, workflow runner, agent SDK, queue, scheduler, database, or extra review framework. The coding agent in the active session is the orchestrator. Terminal and Git are the host's existing tools.
