---
name: autodev
description: Run the full development lifecycle from a requirement or plan until completion or a blocker. Use for autonomous implementation, resume, or status. Do not use for plan-only, a single implement, debug, one review, or review-loop-only.
---

# autodev

**Action now:** run autonomous development until `PASS`, `FAIL`, `INCOMPLETE`, or `BLOCKED`. Do not stop after the plan or between ready tasks — continue in this session.

1. Resolve `B3_HOME` (`B3_HOME` env, product `.b3/home`, or this repo if it contains `workflows/autonomous-development.md`; else `BLOCKED`). Never copy B3 `skills/` into this product repo.
2. Open and follow `{B3_HOME}/workflows/autonomous-development.md` (load skills/rules/agents from `B3_HOME`; write checkpoints under `.b3/autodev/runs/<run_id>/` via `.b3/autodev/CURRENT` and commit in this product repo).
3. Arguments: story/requirement/bug/refactor/plan path → run lifecycle; `resume [<run_id>]` → reconcile & continue; `status [<run_id>|--all]` → report only.
4. Dispatch isolated reviewer/fixer subagents when available; otherwise record the hat-change limit in `{RUN_DIR}/progress.md`.
