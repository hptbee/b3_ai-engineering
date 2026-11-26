---
name: b3-verify
description: Treat a named claim as a verification problem. Run evidence. Label PASS, FAIL, or INCOMPLETE.
---

# b3-verify

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, host global fallback, or this repo), treat a named claim as a verification problem, run evidence (prefer `b3 guard verify-run` / `b3 guard verify-check` for reusable `b3-verify-v1` receipts), and label PASS / FAIL / UNKNOWN / INCOMPLETE.

- **Parallel checks:** per `{B3_HOME}/workflows/references/dispatch-naming.md`, parallelize independent verification commands only when build dirs, DBs, ports, and temp paths are conflict-free (`SHARED_READ_ONLY`); keep exact exit codes and receipts.

**Skill:** `{B3_HOME}/skills/engineering/verification/SKILL.md`

**Rule:** `{B3_HOME}/rules/verification.md`
