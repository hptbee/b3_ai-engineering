# Adaptive PR sizing

Classify **before** the first review. Defaults are for typical application PRs (the product repo under review), not this skills repository’s file counts. Override if the product repo documents different thresholds.

Measure:

- Changed files (`git diff --name-only`)
- Approx added+removed lines
- Logical areas (features, projects, services, UI vs API vs data)
- Architectural boundaries crossed (e.g. API contract + DB + client)
- Whether it is one feature or several

## Classes

| Class | Typical signals (any strong match) |
| --- | --- |
| **SMALL** | ≤ 8 files **and** ≤ 300 lines **and** one logical area |
| **MEDIUM** | ≤ 20 files **and** ≤ 800 lines **and** ≤ 2 areas; still one feature |
| **LARGE** | > MEDIUM, **or** 3+ logical areas, **or** multiple services/modules with distinct contracts |
| **VERY_LARGE** | ≳ 50 files **or** ≳ 2000 lines **or** many services **or** cannot name units without splitting a tightly coupled ball |

When in doubt between SMALL and MEDIUM, use **MEDIUM** (still full-PR loop). When in doubt between MEDIUM and LARGE, prefer **LARGE** only if units would be independently understandable.

## Workflow mapping

| Class | Loop |
| --- | --- |
| SMALL, MEDIUM | Full-PR loop ([`strategy.md`](strategy.md) §1) |
| LARGE, VERY_LARGE | Partition → unit loops → cross-cutting ([`strategy.md`](strategy.md) §2) |

## Partition rules

- Unit = one **logical change** (feature slice, bounded context, contract+handlers+tests).
- Include that unit’s tests with the unit.
- **Bad:** one class / one method / one test file as a unit.
- **If too coupled to partition:** say so; do not invent directories-as-units; recommend splitting the PR.

Cross-cutting review is **not** a unit; it runs after units that are not abandoned.
