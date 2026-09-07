# Review loop (runtime)

Specification: [`docs/review-loop.md`](../docs/review-loop.md).

**Status:** orchestration v1. The agent that receives `commands/review-loop.md` **runs until** a quality gate, non-convergence, or iteration limit. It does not stop after the first findings list for the user to re-trigger.

| File | Role |
| --- | --- |
| [`strategy.md`](strategy.md) | Orchestrator procedure |
| [`sizing.md`](sizing.md) | SMALL / MEDIUM / LARGE / VERY_LARGE |
| [`findings.md`](findings.md) | IDs, lifecycle aliases, iteration log |
| [`models.md`](models.md) | Reviewer / fixer / orchestrator model slots (not hard-coded) |

Review method stays in `skills/engineering/code-review`. Fix method stays in `agents/fixer.md` (minimal change + `verification`). Do not duplicate those bodies here.

Working state may be kept in-session or written under `state/` (gitignored except the template).
