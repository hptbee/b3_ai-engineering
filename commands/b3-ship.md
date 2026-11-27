---
name: b3-ship
description: Run the full development lifecycle from a requirement or plan until completion or a blocker. Use for autonomous end-to-end delivery, resume, or status. Do not use for plan-only, single implement, debug, one review, or review-loop-only.
---

# b3-ship

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, host global fallback, or this repo containing `workflows/ship.md`; else `BLOCKED`) and open `{B3_HOME}/workflows/ship.md` (`Preflight → Plan → [Scope → Build → Verify → Review → Commit] → Finalize`) until `PASS`, `FAIL`, `INCOMPLETE`, or `BLOCKED`. Never copy `skills/` into a product repo. Do not stop after Plan or between ready tasks.

- Arguments: story/requirement/bug/refactor/plan path → run lifecycle; `resume [<run_id>]` → reconcile `.b3/ship/CURRENT` (or `<run_id>`) with Git & continue; `status [<run_id>|--all]` → report only.
- Dispatch isolated reviewer/fixer and independent wave workers continuously per `{B3_HOME}/workflows/references/dispatch-naming.md` (no nested worker fan-out); otherwise record `SINGLE_AGENT_LIMIT` in `{RUN_DIR}/progress.md`.
