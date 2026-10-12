---
name: autodev
description: Run the full development lifecycle from a requirement or plan until completion or a blocker. Use for autonomous implementation, resume, or status. Do not use for plan-only, a single implement, debug, one review, or review-loop-only.
---

# autodev

**Action now:** run autonomous development until completion or an explicit blocker. Do not stop after the plan and wait for `/implement`.

**Workflow:** [`../../workflows/autonomous-development.md`](../../workflows/autonomous-development.md)

| Argument | Behavior |
| --- | --- |
| Story, requirement, bug, refactor, or a path to one | Start or continue the lifecycle |
| Path to an existing plan | Validate it, then execute |
| `resume` | Reconcile `.b3/autodev/` with Git, then continue |
| `status` | Report the checkpoint. Do not implement |

You are the orchestrator in this session. Dispatch reviewer and fixer subagents when this host can isolate them. If it cannot, record that limit in `.b3/autodev/progress.md`.

`/plan`, `/implement`, `/debug`, `/review`, `/verify`, and `/review-loop` stay single-purpose. This command composes them; it does not replace their files.
