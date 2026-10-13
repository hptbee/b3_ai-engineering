---
name: autodev
description: >
  Run the full B3 autonomous development lifecycle from a requirement or plan
  until PASS, FAIL, INCOMPLETE, or BLOCKED. Use when the user says autodev,
  $autodev, /autodev, resume autodev, or autodev status. Do not use for
  plan-only, a single implement, debug, one review, or review-loop-only.
---

# autodev

**Action now:** run autonomous development until `PASS`, `FAIL`, `INCOMPLETE`, or `BLOCKED`. Do not stop after the plan and wait for implement. Do not stop after one task while other ready tasks remain — continue in this session.

This skill exists so **Codex** can discover `$autodev`. The procedure is not duplicated here.

## Locate B3

Resolve `B3_HOME` in this order. Stop at the first match that contains `workflows/autonomous-development.md`:

1. Environment variable `B3_HOME`
2. Product git root file `.b3/home` (one line, absolute path)
3. This repository itself, if it contains `workflows/autonomous-development.md`

If none match → `BLOCKED`. Do not invent a second procedure. Do not copy B3 skills into this product repository.

**Then open and follow:**

1. `{B3_HOME}/.cursor/commands/autodev.md` (or this product `.cursor/commands/autodev.md` if present)
2. `{B3_HOME}/workflows/autonomous-development.md`

Write checkpoints and make Git commits in this product repository. Checkpoints: `.b3/autodev/` (gitignored).

| Argument | Behavior |
| --- | --- |
| Story, requirement, bug, refactor, or a path to one | Start or continue the lifecycle |
| Path to an existing plan | Validate it, then execute |
| `resume` | Reconcile `.b3/autodev/` with Git, then continue |
| `status` | Report the checkpoint. Do not implement |
