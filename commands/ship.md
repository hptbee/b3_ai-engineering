---
name: ship
description: Run the full development lifecycle from a requirement or plan until completion or a blocker. Use for autonomous end-to-end delivery, resume, or status. Do not use for plan-only, single implement, debug, one review, or review-loop-only.
---

# ship

**Action now:** open and follow [`../workflows/ship.md`](../workflows/ship.md) (`Preflight → Plan → [Scope → Gate → Build → Verify → Guard → Review → Fix → Commit] → Finalize`) until `PASS`, `FAIL`, `INCOMPLETE`, or `BLOCKED` (in a product repo, resolve `B3_HOME` from `B3_HOME` env or `.b3/home` and open `{B3_HOME}/workflows/ship.md`; never copy `skills/`). Do not stop after Plan or between ready tasks.

- Arguments: story/requirement/bug/refactor/plan path → run lifecycle; `resume [<run_id>]` → reconcile `.b3/ship/CURRENT` (or `<run_id>`) with Git & continue; `status [<run_id>|--all]` → report only.
- Dispatch isolated reviewer/fixer subagents when available; otherwise record the hat-change limit in `{RUN_DIR}/progress.md`.
