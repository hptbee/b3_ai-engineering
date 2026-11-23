---
name: b3-implement
description: Execute a plan or specified change using the default engineering loop. Use when the user asks to implement, build, or code a change (not full /b3-ship).
---

# b3-implement

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, or this repo) and open `{B3_HOME}/skills/engineering/problem-solving/SKILL.md` directly (+ smallest stack skill for React, Node, ASP.NET, Three.js, etc.).

- Single-hop execution (`Scope -> Plan -> Build -> Verify -> Review -> Fix -> Verify`); do **not** eagerly load `{B3_HOME}/workflows/feature-implementation.md` on routine tasks (reference only).
- If the active host supports subagents and `.b3/models.md` or `~/.b3/models.md` (or `B3_MODELS_PERSONAL`, following `{B3_HOME}/workflows/references/dispatch-naming.md` precedence) sets a non-`auto` `implementation` model differing from `main`, dispatch a `b3-impl-t00N` subagent even for single-task Build instead of coding inline on `main`.
- This stays one execution request: do **not** run the full `/b3-review-loop` (`commands/b3-review-loop.md`) or escalate into `/b3-ship` (`commands/b3-ship.md`) unless explicitly asked.
