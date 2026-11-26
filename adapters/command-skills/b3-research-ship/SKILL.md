---
name: b3-research-ship
description: Research-first autonomous delivery lifecycle from source discovery through verified evidence, optional implementation, PR, and governed merge ($b3-research-ship, /b3-research-ship, b3-research-ship, resume, status).
---

# b3-research-ship

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, or this repo containing `workflows/research-ship.md`; else `BLOCKED`) and open `{B3_HOME}/workflows/research-ship.md` directly (single-hop; never copy `skills/` into a product repo) until terminal status (`PASS` | `PR_READY` | `MERGED_VERIFIED` | `FAIL` | `INCOMPLETE` | `BLOCKED`).

- Arguments: research request / existing plan path → run lifecycle; `resume [<run_id>]` → reconcile `.b3/research-ship/` with Git & source fingerprints and continue; `status [<run_id>|--all]` → read-only report.
- Default merge policy: `auto_merge: disabled` (stop at `PR_READY` or `BLOCKED` unless explicitly authorized); keep `.b3/research-ship/runs/<run_id>/` via `.b3/research-ship/CURRENT` (gitignored), `RESEARCHED != VERIFIED != IMPLEMENTED != RELEASED`, and `PR_MERGED != RUNTIME_SERVED != DEPLOYED`.
