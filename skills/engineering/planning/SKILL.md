---
name: planning
description: "Use when writing a multi-step implementation plan before coding: files, risks, verification, task order. Not for trivial one-file fixes, executing plans (problem-solving), or external repo research."
---

# Planning

Write a plan an agent can execute without inventing scope. No TBD where a decision is required.

Adapted from Superpowers writing-plans (file map, bite-sized tasks, no placeholders) without Superpowers paths, TDD ritual, or subagent-driven execution.

## When to use

- Multi-file or multi-layer feature
- User asks for a plan, design, or breakdown first
- Spec exists but order of work is unclear

## When not to use

- One localized bug with known cause → `debugging`
- User said implement now on a tiny change → `problem-solving`
- Pattern mining → `research-engineering-patterns`
- Per-task implementation approach inside `/b3-ship` → `workflows/ship.md` `Scope` & `Gate` (not a second master plan)

Near miss: “is this architecture sound?” with no implementation yet → this skill plus `architecture/simplest-correct`.

## Procedure

1. **Restate goal & scope** in one sentence, naming explicit **in-scope / out-of-scope** bounds and top-level success evidence (command or probe).
2. **Map files & reuse:** identify files/modules to create or modify following existing project conventions; check existing utilities/architecture first so no duplicate abstraction is invented.
3. **Assess risks (risk-adaptive depth):** list security/authz, data consistency, perf, a11y, or 3D resource risks and matching domain skills.
   - **Low-risk / localized:** keep the plan compact (files, ACs, tasks, checks).
   - **High-risk trigger** (ambiguity, architecture/contract changes, authz boundaries, stateful/concurrency/retry logic, cache/write-path invalidation, cross-module deps): explicitly capture shared contracts/interfaces, failure modes, and write/invalidation paths before task breakdown.
4. **Dependency-ordered tasks:** smallest units independently verifiable, ordered by dependencies (fold scaffolding into the task that needs it).
5. **Each task:** intent, touched files/contracts, dependencies, testable acceptance criteria (`AC1..ACn`), and exact verification command or probe. Resolve decisions upfront — no `TBD`, implicit placeholders, or "add error handling later".
6. **Readiness Check:** confirm every AC is observable/testable & mapped 1:1 to a check, reusable existing code was checked, contradictions/missing requirements/incomplete dependencies are flagged and asked before coding, and design is the simplest sound fit (`architecture/simplest-correct`).
7. **Stop.** Do not write product code unless the user also asked to implement.

## Progressive disclosure

- Execution: `skills/engineering/problem-solving/SKILL.md`
- Workflow: `workflows/feature-implementation.md`
- Autonomous lifecycle: `/b3-ship` Scenario A/B uses this skill for the one master plan. Per-task approach is `workflows/ship.md` `Scope` (`problem-solving` + `Gate`). Do not load this skill again on a ready task.

## Verification

A good plan names how each task will be checked. A plan with only aspirations is incomplete.

## Failure handling

- Requirements conflict → record and ask; do not paper over
- Unknown stack in product repo → read the repo; do not plan a parallel architecture

## Provenance

ADAPT obra/superpowers writing-plans. REJECT docs/superpowers/plans paths and mandatory subagent execution.
