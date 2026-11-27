---
name: b3-plan
description: Explicit command wrapper ($b3-plan, /b3-plan, b3-plan) for scoped plan-only breakdown via planning skill without writing product code. Not for /b3-ship or implementation.
---

# b3-plan

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, host global fallback, or this repo), produce a scoped plan with testable ACs, 1:1 checks, and disjoint `files`/`depends_on` (risk-adaptive depth), and stay plan-only unless implementation was explicitly requested.

- **Skills:** open `{B3_HOME}/skills/engineering/planning/SKILL.md` directly (+ `{B3_HOME}/skills/architecture/simplest-correct/SKILL.md` if choosing system shape).
- **Parallel discovery:** on multi-area work, fan out concurrent `SHARED_READ_ONLY` codebase/dep/risk scouts via `{B3_HOME}/workflows/references/dispatch-naming.md` and synthesize 1 plan; single-area stays inline.
- **Model routing (independent of parallelism):** scheduling (inline vs concurrent scouts) is decided by task scope/dependencies above, never disabled by `model=auto`. If the host supports subagents and `.b3/models.md` or `~/.b3/models.md` (`B3_MODELS_PERSONAL`, per `dispatch-naming.md`) sets a non-`auto` `planning` model differing from `main`, run dispatched planning subagent(s) (or a read-only planning subagent for single-area work) on that model; when `auto`/unset, keep the chosen inline or parallel schedule on `main`'s model.
