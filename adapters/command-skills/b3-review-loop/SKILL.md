---
name: b3-review-loop
description: Run the autonomous independent review loop to completion (quality gate, non-convergence, or iteration limit). Use for iterative review-and-fix, $b3-review-loop, /b3-review-loop, or b3-review-loop. Not for a single review pass.
---

# b3-review-loop

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, or this repo) and run `{B3_HOME}/review-loop/strategy.md` **to completion** (gate, `STUCK`, or cap; never yield after pass 1).

- **Single-hop / lean load:** never load `commands/b3-review-loop.md` or `spec.md`, and skip `sizing.md`, `models.md`, and (for `XS`/`S`/`M`) `hierarchical.md` unless needed; standalone runs store compact state/ledger in `.b3/ship/review-loop/<slug>/` (`verify-run`/`verify-check`, `review-inventory`/`review-ledger`). For 1 pass use `/b3-review`.
