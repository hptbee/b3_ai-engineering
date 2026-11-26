---
name: b3-implement
description: Explicit command wrapper ($b3-implement, /b3-implement, b3-implement) to execute one specified change or plan via problem-solving skill. Not for plan-only or /b3-ship.
---

# b3-implement

**Action now:** execute a plan or specified change as one execution request (do **not** escalate into full `/b3-ship` or `/b3-review-loop` unless asked).

Resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, or this repo) and open `{B3_HOME}/skills/engineering/problem-solving/SKILL.md` + the smallest matching stack skill (`skills/{frontend,backend,threejs,architecture}/*`) directly (single-hop; skip `workflows/feature-implementation.md` on routine runs).

If the active host supports subagents and `.b3/models.md` or `~/.b3/models.md` (or `B3_MODELS_PERSONAL`, following `{B3_HOME}/workflows/references/dispatch-naming.md` precedence) sets a non-`auto` `implementation` model differing from `main`, dispatch a `b3-impl-t00N` subagent even for single-task Build instead of coding inline on `main`.
