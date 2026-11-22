---
name: ship
description: Run the full development lifecycle from a requirement or plan until completion or a blocker. Use for autonomous end-to-end delivery, resume, or status. Do not use for plan-only, single implement, debug, one review, or review-loop-only.
---

# ship

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, or this repo containing `workflows/ship.md`; else `BLOCKED`) and open `{B3_HOME}/workflows/ship.md` (`Preflight → Plan → [Scope → Gate → Build → Verify → Guard → Review → Fix → Commit] → Finalize`) until `PASS`, `FAIL`, `INCOMPLETE`, or `BLOCKED`. Never copy `skills/` into a product repo. Do not stop after Plan or between ready tasks.

- Arguments: story/requirement/bug/refactor/plan path → run lifecycle; `resume [<run_id>]` → reconcile `.b3/ship/CURRENT` (or `<run_id>`) with Git & continue; `status [<run_id>|--all]` → report only.
- Dispatch isolated reviewer/fixer subagents when available; otherwise record the hat-change limit in `{RUN_DIR}/progress.md`.
