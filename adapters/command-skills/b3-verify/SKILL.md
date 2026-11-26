---
name: b3-verify
description: Explicit command wrapper ($b3-verify, /b3-verify, b3-verify) to run executed evidence for a named claim via verification skill (PASS, FAIL, or INCOMPLETE).
---

# b3-verify

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, host global fallback, or this repo), treat a named claim as a verification problem, run evidence (prefer `b3 guard verify-run` / `b3 guard verify-check` for reusable `b3-verify-v1` receipts), and label `PASS` / `FAIL` / `UNKNOWN / INCOMPLETE`. Parallelize independent checks only when build dirs, DBs, ports, and temps are conflict-free (`SHARED_READ_ONLY` via `{B3_HOME}/workflows/references/dispatch-naming.md`), preserving exact exit codes and receipts.

Open `{B3_HOME}/skills/engineering/verification/SKILL.md` (`{B3_HOME}/rules/verification.md`).
