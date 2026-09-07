---
name: planning
description: >
  Use when producing an implementation plan before coding a multi-step
  change: files, risks, verification, task order. Do not use for a single
  obvious one-file fix, for executing the plan (problem-solving), or for
  researching external repos.
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

Near miss: “is this architecture sound?” with no implementation yet → this skill plus `architecture/simplest-correct`.

## Procedure

1. **Restate goal** in one sentence and success evidence (what will be run).
2. **Map files** to create/modify; follow existing project layout.
3. **List risks** (auth, data, perf, a11y, 3D resources) and which skill applies.
4. **Tasks:** smallest units that are independently verifiable. Fold scaffolding into the task that needs it.
5. **Each task:** intent, files, verification command or probe. No “add error handling later”.
6. **Self-check:** every spec item has a task; names/types consistent; simplest approach that meets requirements (`architecture/simplest-correct`).
7. **Stop.** Do not start coding unless the user asked to execute.

## Progressive disclosure

- Execution: `skills/engineering/problem-solving/SKILL.md`
- Workflow: `workflows/feature-implementation.md`

## Verification

A good plan names how each task will be checked. A plan with only aspirations is incomplete.

## Failure handling

- Requirements conflict → record and ask; do not paper over
- Unknown stack in product repo → read the repo; do not plan a parallel architecture

## Provenance

ADAPT obra/superpowers writing-plans. REJECT docs/superpowers/plans paths and mandatory subagent execution.
