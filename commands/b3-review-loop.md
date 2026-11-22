---
name: b3-review-loop
description: Run the autonomous independent review loop to completion (quality gate, non-convergence, or iteration limit). Use when the user wants iterative review-and-fix, not a single pass.
---

# b3-review-loop

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, or this repo) and open `{B3_HOME}/review-loop/strategy.md` **to completion** (quality gate, `STUCK`, or iteration cap). Do not stop after the first findings list.

- **Context budget:** `strategy.md` is self-contained at runtime — do **not** load `spec.md`, `sizing.md`, or `models.md` unless an edge case requires disambiguation.
- You are the orchestrator: dispatch Reviewer (`{B3_HOME}/agents/b3-reviewer.md`) and Fixer (`{B3_HOME}/agents/b3-fixer.md`) in separate passes (subagents if available, else strict hat-change logging `review_independence: SINGLE_AGENT_LIMIT`). Only you declare `PASS` / `FAIL` / `STUCK` / `INCOMPLETE`.
- Standalone runs without `/b3-ship` persist optional compact state in `.b3/ship/review-loop/<slug>/` (`state.md`, `logs/`, `evidence/verify.verify`) and validate fixes via `b3-guard verify-run`/`verify-check`.
- Single-pass review remains `/b3-review` (`commands/b3-review.md`).
