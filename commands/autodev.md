---
name: autodev
description: Run the full development lifecycle from a requirement or plan until completion or a blocker. Use for autonomous implementation, resume, or status. Do not use for plan-only, a single implement, debug, one review, or review-loop-only.
---

# autodev

**Action now:** open and follow [`../workflows/autonomous-development.md`](../workflows/autonomous-development.md) until `PASS`, `FAIL`, `INCOMPLETE`, or `BLOCKED` (if installed in a product repo, resolve `B3_HOME` from `B3_HOME` env or `.b3/home` and open `{B3_HOME}/workflows/autonomous-development.md`; never copy `skills/`). Do not stop after the plan or between ready tasks.

- Arguments: story/requirement/bug/refactor/plan path → run lifecycle; `resume [<run_id>]` → reconcile `.b3/autodev/CURRENT` (or `<run_id>`) with Git & continue; `status [<run_id>|--all]` → report only.
- Dispatch isolated reviewer/fixer subagents when available; otherwise record the hat-change limit in `{RUN_DIR}/progress.md`.
