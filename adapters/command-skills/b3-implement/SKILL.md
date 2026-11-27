---
name: b3-implement
description: Explicit command wrapper ($b3-implement, /b3-implement, b3-implement) to execute one specified change or plan via problem-solving skill. Not for plan-only or /b3-ship.
---

# b3-implement

**Action now:** execute a plan or specified change as one execution request (do **not** escalate into full `/b3-ship` or `/b3-review-loop` unless asked).

Resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, host global fallback, or this repo) and open `{B3_HOME}/skills/engineering/problem-solving/SKILL.md` + the smallest matching stack skill (`skills/{frontend,backend,threejs,architecture}/*`) directly (single-hop; skip `workflows/feature-implementation.md` on routine runs).

Follow `{B3_HOME}/workflows/references/dispatch-naming.md` and `.b3/models.md` / `~/.b3/models.md` (`B3_MODELS_PERSONAL`): 1-slice `XS` + `inline` runs inline when `implementation` is unset/`auto`; multi-slice work validates disjoint impl/test/doc slices via `b3 guard check-wave --partition` and dispatches `b3-impl-t00N` (no nested subagents) + concurrent `SHARED_READ_ONLY` risk-triggered reviewers (or when `implementation` differs from `main`).
