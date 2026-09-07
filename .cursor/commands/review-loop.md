# review-loop

**Action now:** run the autonomous review loop **to completion** (gate, stuck, or limit). Do not stop after the first findings list for the user to re-invoke this command.

**Orchestrator:** [`review-loop/strategy.md`](../review-loop/strategy.md)

**Spec:** [`docs/review-loop.md`](../docs/review-loop.md)

```text
Review → validate findings → fix valid ones → build/test → fresh review → …
```

- Size the PR first (`review-loop/sizing.md`). Small/medium = full-PR loop. Large = unit loops, then cross-cutting review.
- Reviewer does not edit. Fixer does not declare PASS.
- One `review` command remains a **single** pass (`commands/review.md`).

If the host supports subagents, dispatch `agents/reviewer.md` and `agents/fixer.md` separately (`review-loop/models.md`).
