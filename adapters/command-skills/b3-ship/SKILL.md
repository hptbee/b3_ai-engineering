---
name: b3-ship
description: Run the full B3 autonomous lifecycle until PASS, FAIL, INCOMPLETE, or BLOCKED ($b3-ship, /b3-ship, b3-ship, ship lifecycle, resume, status). Not for plan-only, single implement, debug, single review, or review-loop-only.
---

# b3-ship

**Action now:** run the full lifecycle (`Preflight → Plan → [Scope → Build → Verify → Review → Commit] → Finalize`) until `PASS`, `FAIL`, `INCOMPLETE`, or `BLOCKED`. Do not stop after Plan or between ready tasks — continue in this session.

1. Resolve `B3_HOME` (first match containing `workflows/ship.md`: `B3_HOME` env, product `.b3/home`, host global fallback, or this repo; else `BLOCKED`). Never copy B3 `skills/` into the product repo.
2. **Single-hop load:** open and follow `{B3_HOME}/workflows/ship.md` directly (do not waste a hop reading `commands/b3-ship.md`).
3. Write checkpoints under `.b3/ship/runs/<run_id>/` via `.b3/ship/CURRENT` (gitignored) and commit in this product repo. Dispatch isolated reviewer/fixer subagents when available; otherwise record the hat-change limit in `{RUN_DIR}/progress.md`.
4. Arguments: story/requirement/bug/refactor/plan path → run lifecycle; `resume [<run_id>]` → reconcile & continue; `status [<run_id>|--all]` → report only.
