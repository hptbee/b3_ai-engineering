---
name: b3-research-ship
description: >
  Research-first autonomous delivery lifecycle from source discovery through
  verified evidence, optional implementation, PR, and governed merge
  ($b3-research-ship, /b3-research-ship, resume, status).
---

# b3-research-ship

**Action now:** run the research-first lifecycle (`{B3_HOME}/workflows/research-ship.md`) until `PASS`, `PR_READY`, `MERGED_VERIFIED`, `FAIL`, `INCOMPLETE`, or `BLOCKED`.

1. Resolve `B3_HOME` (first directory containing `workflows/research-ship.md`: `B3_HOME` env, `.b3/home`, or this repo; else `BLOCKED`). Never copy `skills/` into a product repo.
2. **Single-hop load:** open `{B3_HOME}/workflows/research-ship.md` directly.
3. Store checkpoints in `.b3/research-ship/runs/<run_id>/` via `.b3/research-ship/CURRENT` (gitignored); keep source verification separate from engineering tests and `auto_merge: disabled` by default.
4. Arguments: research request / plan path → run lifecycle; `resume [<run_id>]` → reconcile & continue; `status [<run_id>|--all]` → report only.
