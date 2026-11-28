---
name: b3-implement
description: Execute a plan or specified change using the default engineering loop. Use when the user asks to implement, build, or code a change (not full /b3-ship).
---

# b3-implement

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, host global fallback, or this repo) and open `{B3_HOME}/skills/engineering/problem-solving/SKILL.md` directly (+ smallest stack skill for React, Node, ASP.NET, Three.js, etc.).

- Single-hop execution (`Scope -> Plan -> Build -> Verify -> Review -> Fix -> Verify`); do **not** eagerly load `{B3_HOME}/workflows/feature-implementation.md` on routine tasks (reference only).
- Follow `{B3_HOME}/workflows/references/dispatch-naming.md` and `b3 config get --route implementation`: run 1-slice `XS` + `inline` builds inline on `main` when `implementation` resolves to `auto`; for multi-slice work, run `b3 guard check-wave --partition` and dispatch concurrent disjoint impl/test/doc slices (`b3-impl-t00N`, no nested subagents) + concurrent `SHARED_READ_ONLY` risk-triggered reviewers (or when a non-`auto` `implementation` model differs from `main`).
- This stays one execution request: do **not** run `/b3-review-loop` (`commands/b3-review-loop.md`) or escalate into `/b3-ship` (`commands/b3-ship.md`) unless explicitly asked.
