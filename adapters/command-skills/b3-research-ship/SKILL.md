---
name: b3-research-ship
description: "Full research-to-delivery lifecycle: discovery, verification, optional impl, PR, and merge ($b3-research-ship, /b3-research-ship). Not lightweight /b3-research."
---

# b3-research-ship

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, host global fallback, or this repo containing `workflows/research-ship.md`; else `BLOCKED`) and open `{B3_HOME}/workflows/research-ship.md` directly (single-hop; never copy `skills/` into a product repo) until terminal status (`PASS` | `PR_READY` | `LOCAL_ELIGIBLE_ONLY` | `MERGED_VERIFIED` | `FAIL` | `INCOMPLETE` | `BLOCKED`).

- Arguments: research request / existing plan path → run lifecycle; `resume [<run_id>]` → reconcile `.b3/research-ship/` with Git & source fingerprints and continue; `status [<run_id>|--all]` → read-only report.
- Provider-neutral governance: works in local Git repos (`mode=local`, `LOCAL_ELIGIBLE_ONLY`) and with the optional GitHub PR adapter (`mode=github`, `PROVIDER_UNAVAILABLE` stop on outage). Default `auto_merge: disabled` stops at `PR_READY` or `BLOCKED` unless canonical trunk policy authorizes `auto_merge`. Keep `.b3/research-ship/runs/<run_id>/` via `.b3/research-ship/CURRENT` (gitignored), `RESEARCHED != VERIFIED != IMPLEMENTED != RELEASED`, `PR_MERGED != RUNTIME_SERVED != DEPLOYED`, and continuous parallel research/verification/disjoint impl via `{B3_HOME}/workflows/references/dispatch-naming.md` with single-writer parent governance.
