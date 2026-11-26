---
name: b3-plan
description: Produce an implementation plan without writing product code. Use when the user wants a plan, breakdown, or design-before-code.
---

# b3-plan

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, host global fallback, or this repo) and produce a scoped, dependency-aware implementation plan; keep small edits lightweight and stay plan-only unless implementation was explicitly requested.

- **Skill:** `{B3_HOME}/skills/engineering/planning/SKILL.md` (+ `{B3_HOME}/skills/architecture/simplest-correct/SKILL.md` when choosing system shape).
- **Model preference:** if the host supports subagents and `.b3/models.md` or `~/.b3/models.md` (`B3_MODELS_PERSONAL`, per `{B3_HOME}/workflows/references/dispatch-naming.md`) sets a non-`auto` `planning` model differing from `main`, dispatch a read-only planning subagent on that model; otherwise plan inline on `main`.
