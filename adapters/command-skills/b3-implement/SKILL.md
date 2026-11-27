---
name: b3-implement
description: Explicit command wrapper ($b3-implement, /b3-implement, b3-implement) to execute one specified change or plan via problem-solving skill. Not for plan-only or /b3-ship.
---

# b3-implement

**Action now:** execute a plan or specified change as one execution request (`Scope -> Plan -> Build -> Verify -> Review -> Fix -> Verify`; do **not** run `/b3-review-loop` or escalate into full `/b3-ship` unless explicitly asked).

Resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, host global fallback, or this repo) and open `{B3_HOME}/skills/engineering/problem-solving/SKILL.md` + the smallest matching stack skill (`skills/{frontend,backend,threejs,architecture}/*`) directly (single-hop; skip `workflows/feature-implementation.md` on routine tasks).

Follow `{B3_HOME}/workflows/references/dispatch-naming.md` and `.b3/models.md` / `~/.b3/models.md` (`B3_MODELS_PERSONAL`): run 1-slice `XS` + `inline` builds inline on `main` when `implementation` is unset/`auto`; for multi-slice work, run `b3 guard check-wave --partition` and dispatch concurrent disjoint impl/test/doc slices (`b3-impl-t00N`, no nested subagents) + concurrent `SHARED_READ_ONLY` risk-triggered reviewers (or when a non-`auto` `implementation` model differs from `main`).
