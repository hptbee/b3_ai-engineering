---
name: autodev
description: >
  Run the full B3 autonomous lifecycle until PASS, FAIL, INCOMPLETE, or
  BLOCKED (autodev, $autodev, /autodev, resume, status). Not for
  plan-only, single implement, debug, single review, or review-loop-only.
---

# autodev

**Action now:** run autonomous development until `PASS`, `FAIL`, `INCOMPLETE`, or `BLOCKED`. Do not stop after the plan or between ready tasks — continue in this session.

1. Resolve `B3_HOME` (first match containing `workflows/autonomous-development.md`: `B3_HOME` env, product `.b3/home`, or this repo; else `BLOCKED`). Never copy B3 `skills/` into the product repo.
2. **Single-hop load:** open and follow `{B3_HOME}/workflows/autonomous-development.md` directly (do not waste a hop reading `commands/autodev.md`).
3. Write checkpoints under `.b3/autodev/runs/<run_id>/` via `.b3/autodev/CURRENT` (gitignored) and commit in this product repo. Dispatch isolated reviewer/fixer subagents when available; otherwise record the hat-change limit in `{RUN_DIR}/progress.md`.
4. Arguments: story/requirement/bug/refactor/plan path → run lifecycle; `resume [<run_id>]` → reconcile & continue; `status [<run_id>|--all]` → report only.
