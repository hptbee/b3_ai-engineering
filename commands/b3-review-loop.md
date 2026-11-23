---
name: b3-review-loop
description: Run the autonomous independent review loop to completion (quality gate, non-convergence, or iteration limit). Use when the user wants iterative review-and-fix, not a single pass.
---

# b3-review-loop

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, or this repo) and run `{B3_HOME}/review-loop/strategy.md` **to completion** (gate, `STUCK`, or cap; never yield after pass 1).

- **Lean load:** skip `spec.md`, `sizing.md`, and `models.md` unless disambiguating; standalone runs store compact state in `.b3/ship/review-loop/<slug>/` (`verify-run`/`verify-check`). For 1 pass use `/b3-review`.
