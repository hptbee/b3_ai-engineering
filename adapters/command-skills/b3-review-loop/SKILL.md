---
name: b3-review-loop
description: "Autonomous independent review-and-fix loop to completion: gate, stuck, or cap ($b3-review-loop, /b3-review-loop). Not for single-pass /b3-review."
---

# b3-review-loop

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, host global fallback, or this repo) and run `{B3_HOME}/review-loop/strategy.md` **to completion** (gate, `STUCK`, or cap; never yield after pass 1).

- **Single-hop / lean load:** never load `commands/b3-review-loop.md` or `spec.md`, and skip `sizing.md`, `models.md`, and (for `XS`/`S`/`M`) `hierarchical.md` unless needed; standalone runs store compact state/ledger in `.b3/ship/review-loop/<slug>/` (`b3 guard verify-run`/`verify-check`, `review-inventory`/`review-ledger`). Use `{B3_HOME}/workflows/references/dispatch-naming.md` for adaptive concurrent `SHARED_READ_ONLY` reviews and disjoint fixes. For 1 pass use `/b3-review`.
