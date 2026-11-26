---
name: b3-plan
description: Explicit command wrapper ($b3-plan, /b3-plan, b3-plan) for scoped plan-only breakdown via planning skill without writing product code. Not for /b3-ship or implementation.
---

# b3-plan

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, host global fallback, or this repo), produce a scoped plan with testable ACs and 1:1 checks (risk-adaptive depth), and stay plan-only unless implementation was explicitly requested.

- **Skills:** open `{B3_HOME}/skills/engineering/planning/SKILL.md` directly (+ `{B3_HOME}/skills/architecture/simplest-correct/SKILL.md` if choosing system shape).
- **Model preference:** if the host supports subagents and `.b3/models.md` or `~/.b3/models.md` (`B3_MODELS_PERSONAL`, per `{B3_HOME}/workflows/references/dispatch-naming.md`) sets a non-`auto` `planning` model differing from `main`, dispatch a read-only planning subagent on that model; otherwise plan inline on `main`.
