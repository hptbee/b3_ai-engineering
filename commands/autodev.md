---
name: autodev
description: Run the full development lifecycle from a requirement or plan until completion or a blocker. Use for autonomous implementation, resume, or status. Do not use for plan-only, a single implement, debug, one review, or review-loop-only.
---

# autodev

**Action now:** run autonomous development until `PASS`, `FAIL`, `INCOMPLETE`, or `BLOCKED`. Do not stop after the plan and wait for `/implement`. Do not stop after one task while other ready tasks remain — continue in this session (see workflow **Continue**). Do not tell the user to run `/autodev resume` unless the host session actually ended or the run is blocked.

**Workflow:** [`../workflows/autonomous-development.md`](../workflows/autonomous-development.md)

If that relative path is missing (this command was installed in a product repository), resolve `B3_HOME` then open `{B3_HOME}/workflows/autonomous-development.md`. Order: `B3_HOME` environment variable, then product `.b3/home`, then this repository if it contains that workflow file. Do not copy B3 skills into the product repository.

| Argument | Behavior |
| --- | --- |
| Story, requirement, bug, refactor, or a path to one | Start or continue the lifecycle |
| Path to an existing plan | Validate it, then execute |
| `resume [<run_id>]` | Reconcile active run (`.b3/autodev/CURRENT` or `<run_id>`) with Git, then continue |
| `status [<run_id>\|--all]` | Report the resolved run (or list runs on `--all`). Do not implement |

You are the orchestrator in this session. Dispatch reviewer and fixer subagents when this host can isolate them. If it cannot, record that limit in `{RUN_DIR}/progress.md` (under `.b3/autodev/runs/<run_id>/`).

`/plan`, `/implement`, `/debug`, `/review`, `/verify`, and `/review-loop` stay single-purpose. This command composes them; it does not replace their files.
