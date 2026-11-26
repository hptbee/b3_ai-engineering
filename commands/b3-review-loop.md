---
name: b3-review-loop
description: Run the autonomous independent review loop to completion (quality gate, non-convergence, or iteration limit). Use when the user wants iterative review-and-fix, not a single pass.
---

# b3-review-loop

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, host global fallback, or this repo) and run `{B3_HOME}/review-loop/strategy.md` **to completion** (gate, `STUCK`, or cap; never yield after pass 1).

- **Lean load:** skip `spec.md`, `sizing.md`, `models.md`, and (for `XS`/`S`/`M`) `hierarchical.md` unless needed; standalone runs store compact state/ledger in `.b3/ship/review-loop/<slug>/` (`b3 guard verify-run`/`verify-check`, `review-inventory`/`review-ledger`). Run independent unit/specialist reviews (`SHARED_READ_ONLY`) and non-overlapping confirmed fixes concurrently per `{B3_HOME}/workflows/references/dispatch-naming.md`. For 1 pass use `/b3-review`.
