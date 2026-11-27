---
name: b3-plan
description: Produce an implementation plan without writing product code. Use when the user wants a plan, breakdown, or design-before-code.
---

# b3-plan

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, host global fallback, or this repo) and produce a scoped, dependency-aware implementation plan; keep single-area edits inline/lightweight and stay plan-only unless implementation was explicitly requested.

- **Skill:** `{B3_HOME}/skills/engineering/planning/SKILL.md` (+ `{B3_HOME}/skills/architecture/simplest-correct/SKILL.md` when choosing system shape).
- **Parallel discovery & dispatch:** on multi-area work, run concurrent `SHARED_READ_ONLY` codebase, dependency, and risk discovery per `{B3_HOME}/workflows/references/dispatch-naming.md`; Parent synthesizes 1 plan tagging disjoint `files` and `depends_on`. Single-area work stays inline.
- **Model routing (independent of parallelism):** scheduling (inline vs concurrent scouts) is decided by task scope/dependencies above, never disabled by `model=auto`. If the host supports subagents and `.b3/models.md` or `~/.b3/models.md` (`B3_MODELS_PERSONAL`, per `dispatch-naming.md`) sets a non-`auto` `planning` model differing from `main`, run dispatched planning subagent(s) (or a read-only planning subagent for single-area work) on that model; when `auto`/unset, keep the chosen inline or parallel schedule on `main`'s model.
