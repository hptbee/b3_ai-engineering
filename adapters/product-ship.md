---
name: ship
description: Run the full development lifecycle from a requirement or plan until completion or a blocker. Use for autonomous end-to-end delivery, resume, or status. Do not use for plan-only, single implement, debug, one review, or review-loop-only.
---

# ship

**Action now:** run full `/ship` lifecycle until `PASS`, `FAIL`, `INCOMPLETE`, or `BLOCKED`. Do not stop after Plan or between ready tasks — continue in this session.

1. Resolve `B3_HOME` (`B3_HOME` env, product `.b3/home`, or this repo if it contains `workflows/ship.md`; else `BLOCKED`). Never copy B3 `skills/` into this product repo.
2. Open and follow `{B3_HOME}/workflows/ship.md` (load skills/rules/agents from `B3_HOME`; write checkpoints under `.b3/ship/runs/<run_id>/` via `.b3/ship/CURRENT` and commit in this product repo).
3. Arguments: story/requirement/bug/refactor/plan path → run lifecycle; `resume [<run_id>]` → reconcile & continue; `status [<run_id>|--all]` → report only.
4. Dispatch isolated reviewer/fixer subagents when available; otherwise record the hat-change limit in `{RUN_DIR}/progress.md`.
