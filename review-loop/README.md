# Review loop

| Piece | File | Kind |
| --- | --- | --- |
| Contract | [`spec.md`](spec.md) | Portable specification |
| Procedure | [`strategy.md`](strategy.md) | Orchestrator steps |
| Sizing | [`sizing.md`](sizing.md) | SMALL / MEDIUM / LARGE / VERY_LARGE |
| Findings | [`findings.md`](findings.md) | IDs, lifecycle aliases, iteration log |
| Model slots | [`models.md`](models.md) | Reviewer / fixer / orchestrator (not hard-coded) |
| State | `state/` (gitignored except [`state/TEMPLATE.md`](state/TEMPLATE.md)) | Optional working log |
| Invoke | `.cursor/commands/review-loop.md` | Cursor command |
| Roles | `.cursor/agents/` | Cursor subagents |

**Status:** orchestration v1. The agent that receives `/review-loop` **runs until** a quality gate, non-convergence, or iteration limit. It does not stop after the first findings list for the user to re-trigger.

Review method stays in `.cursor/skills/engineering/code-review`. Fix method stays in `.cursor/agents/fixer.md`. Do not duplicate those bodies here.

This is agent procedure, not a host plugin or eval runner.
