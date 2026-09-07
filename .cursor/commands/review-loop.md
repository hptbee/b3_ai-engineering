---
name: review-loop
description: Run the autonomous independent review loop to completion (quality gate, non-convergence, or iteration limit). Use when the user wants iterative review-and-fix, not a single pass.
---

# review-loop

**Action now:** run the autonomous review loop **to completion** (gate, stuck, or limit). Do not stop after the first findings list for the user to re-invoke this command.

**Orchestrator:** [`review-loop/strategy.md`](../../review-loop/strategy.md)

**Spec:** [`review-loop/spec.md`](../../review-loop/spec.md)

```text
Review → validate findings → fix valid ones → build/test → fresh review → …
```

- Size the PR first (`review-loop/sizing.md`). Small/medium = full-PR loop. Large = unit loops, then cross-cutting review.
- Reviewer does not edit. Fixer does not declare PASS.
- One `review` command remains a **single** pass (`.cursor/commands/review.md`).

If the host supports subagents, dispatch `.cursor/agents/reviewer.md` and `.cursor/agents/fixer.md` separately (`review-loop/models.md`).
