---
name: b3-research-ship
description: Run the research-first autonomous delivery lifecycle from research through verified evidence, formalization, optional implementation, PR, and governed merge evaluation.
---

# b3-research-ship

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, or this repo containing `workflows/research-ship.md`; else `BLOCKED`) and open `{B3_HOME}/workflows/research-ship.md` (`Preflight → Research Planning → Source Discovery → Analysis → Independent Verification → Formalization → [Implementation → Review/Editorial] → PR → Merge Eligibility → Post-Merge`).

- Arguments: research request / existing plan path → run lifecycle; `resume [<run_id>]` → reconcile `.b3/research-ship/` with Git & source fingerprints and continue; `status [<run_id>|--all]` → read-only report.
- Default merge policy: `auto_merge: disabled` (stop at `PR_READY` or `BLOCKED` unless explicitly authorized). Keep `RESEARCHED != VERIFIED != IMPLEMENTED != RELEASED` and `PR_MERGED != RUNTIME_SERVED != DEPLOYED`.
