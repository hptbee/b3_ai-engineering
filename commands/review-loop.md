---
name: review-loop
description: Run the autonomous independent review loop to completion (quality gate, non-convergence, or iteration limit). Use when the user wants iterative review-and-fix, not a single pass.
---

# review-loop

**Action now:** open and follow [`../review-loop/strategy.md`](../review-loop/strategy.md) **to completion** (quality gate, `STUCK`, or iteration cap). Do not stop after the first findings list.

- **Context budget:** `strategy.md` is self-contained at runtime — do **not** load `spec.md`, `sizing.md`, `findings.md`, or `models.md` unless an edge case requires disambiguation.
- You are the orchestrator: dispatch Reviewer (`agents/reviewer.md`) and Fixer (`agents/fixer.md`) in separate passes (subagents if available, else strict hat-change). Only you declare `PASS` / `FAIL` / `STUCK` / `INCOMPLETE`.
- Single-pass review remains `commands/review.md`.
