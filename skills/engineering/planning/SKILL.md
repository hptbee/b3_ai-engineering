---
name: planning
description: "Use when writing a multi-step implementation plan before coding: files, risks, verification, task order. Not for trivial one-file fixes, executing plans (problem-solving), or external repo research."
---

# Planning

Write an executable plan without inventing scope, optimizing **verified independent completion** and **useful parallelism**. No `TBD` where a decision is required.

## When to use / not use

- **Use:** multi-file/layer work; user asks for plan/design/breakdown first; unclear execution order; architecture soundness check (+ `architecture/simplest-correct`).
- **Skip:** localized bug with known cause (`debugging`); tiny edit now (`problem-solving`); pattern mining (`research-engineering-patterns`); per-task `/b3-ship` approach (`workflows/ship.md` `Scope` & `Gate`).

## Procedure

1. **Goal & bounds:** 1 sentence naming explicit **in-scope / out-of-scope** bounds and top-level success evidence (command/probe).
2. **Map files, reuse & proportionality:** fan out concurrent `SHARED_READ_ONLY` scouts on multi-area work (`workflows/references/dispatch-naming.md`); keep single-area inline. Reuse existing modules, native features, and stdlibs; prefer simple configs/direct flows over custom frameworks unless justified by a named requirement (`architecture/simplest-correct`).
3. **Risk-adaptive depth:** list security/authz, data-consistency, perf, a11y, or 3D resource risks + domain skills.
   - **Low-risk:** compact (`files`, ACs, tasks, checks).
   - **High-risk** (ambiguity, contract/schema/authz changes, concurrency/retry/state, cache/write invalidation, cross-module deps): capture shared contracts, failure modes, and write/invalidation paths before breakdown.
4. **Cohesive sizing, 3-way dependencies & critical path:** Parent synthesizes 1 plan:
   - **Cohesive sizing & shared prerequisites:** Treat `>~800 LOC`, `>2` areas, or unrelated subsystems as a split heuristic, not mandatory fragmentation. Extract small shared contracts early so downstream tasks unlock in parallel; avoid oversized blockers or tiny slices where dispatch exceeds inline cost. Keep modules paired with their unit tests unless test scaffolding is independent.
   - **3-way dependency classification (existing plan fields — no extra schema):**
     - *Hard dependency (`depends_on`):* `B` needs `A`'s verified output before starting; never add fake sequential `depends_on` for ordering comfort.
     - *Read/write conflict (`files` + `read_only_deps`):* concurrent writes/reads would race (`check-wave --partition` orders/isolates them without fake `depends_on`).
     - *Integration constraint:* outputs require serialized commit, single-writer manifest/ledger update, or isolated-worktree integration before downstream use.
   - **Critical-path ordering:** Order ready tasks by downstream tasks unlocked, grounded complexity/expected runtime (no speculative telemetry), and risk/isolation cost so critical-path blockers start first.
5. **Per-task contract:** intent, `files`/`read_only_deps`/contracts, dependencies, testable `AC1..ACn`, and exact check command/probe. Resolve decisions upfront (no `TBD` or deferred error handling).
6. **Readiness & stop:** confirm clarity gate passes (`workflows/references/clarification-gate.md`), 1:1 AC-to-check mapping, reuse checked, simplest-correct fit, and flag/ask contradictions or missing deps before coding. **Stop** unless asked to implement.

## Links, failure handling & provenance

- Execution: `skills/engineering/problem-solving/SKILL.md` (`workflows/feature-implementation.md`); clarification gate: `workflows/references/clarification-gate.md`; `/b3-ship` uses this skill once for `master-plan.md`.
- Conflict → record & ask; unknown stack → read repo (never invent parallel architecture); aspirations without checks → incomplete.
- ADAPT `obra/superpowers` `writing-plans`; REJECT `docs/superpowers/plans` paths and mandatory subagents.
