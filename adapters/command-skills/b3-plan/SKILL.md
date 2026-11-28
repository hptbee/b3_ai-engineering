---
name: b3-plan
description: "Scoped plan-only breakdown via planning skill without editing product code ($b3-plan, /b3-plan). Not for /b3-ship or impl."
---

# b3-plan

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, host global fallback, or this repo), produce a scoped plan with testable ACs, 1:1 checks, and explicit `files`/`read_only_deps`/`depends_on` (risk-adaptive depth), and stay plan-only unless implementation was explicitly requested.

- **Skills:** open `{B3_HOME}/skills/engineering/planning/SKILL.md` directly (+ `{B3_HOME}/skills/architecture/simplest-correct/SKILL.md` if choosing system shape).
- **Parallel discovery:** on multi-area work, fan out concurrent `SHARED_READ_ONLY` codebase/dep/risk scouts via `{B3_HOME}/workflows/references/dispatch-naming.md` and synthesize 1 plan; single-area stays inline.
- **Sizing, 3-way deps & critical path:** size cohesively (`>~800 LOC`/`>2` areas heuristic, module + unit tests paired, no micro-slices), extract small shared contracts early so dependents unlock in parallel, separate hard `depends_on` vs `files`+`read_only_deps` RW conflicts vs single-writer/worktree integration constraints (no fake `depends_on`), and order ready tasks by downstream unlocks, grounded complexity/runtime, and risk/isolation cost.
- **Model routing (independent of parallelism):** scheduling (inline vs concurrent scouts) is decided by task scope/dependencies above, never disabled by `model=auto`. Resolve `b3 config get --route planning` per `dispatch-naming.md`: if the host supports subagents and the routed `planning` model differs from `main` (non-`auto`), run dispatched planning subagent(s) (or a read-only planning subagent for single-area work) on that model; when `auto`/unset, keep the chosen inline or parallel schedule on `main`'s model.
