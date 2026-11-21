---
name: implement
description: >
  Execute a plan or specified change using the default engineering loop. Use
  when the user asks to implement, build, ship, $implement, or /implement.
  Do not use for plan-only, debug-before-cause, or full autodev.
---

# implement

**Action now:** execute a plan or specified change as one execution request (not full `/autodev` or `/review-loop` unless asked).

Resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, or this repo), open `{B3_HOME}/skills/engineering/problem-solving/SKILL.md` + the smallest matching stack skill (`skills/{frontend,backend,threejs,architecture}/*`), and follow `{B3_HOME}/workflows/feature-implementation.md`.
