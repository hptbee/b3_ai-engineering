---
name: b3-review-loop
description: >
  Run the autonomous independent review loop to completion (quality gate,
  non-convergence, or iteration limit). Use when the user wants iterative
  review-and-fix, $b3-review-loop, or /b3-review-loop. Do not use for a single
  review pass.
---

# b3-review-loop

**Action now:** run the autonomous review loop **to completion** (gate, `STUCK`, or cap). Never yield after pass 1.

Resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, or this repo) and open `{B3_HOME}/review-loop/strategy.md` directly (single-hop; do not load `commands/b3-review-loop.md` or `review-loop/spec.md` on normal runs).
