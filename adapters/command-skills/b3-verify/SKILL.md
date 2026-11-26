---
name: b3-verify
description: Explicit command wrapper ($b3-verify, /b3-verify, b3-verify) to run executed evidence for a named claim via verification skill (PASS, FAIL, or INCOMPLETE).
---

# b3-verify

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, host global fallback, or this repo), treat a named claim as a verification problem, run evidence (prefer `{B3_HOME}/scripts/b3-guard.{ps1,sh} verify-run` / `verify-check` for reusable `b3-verify-v1` receipts), and label `PASS` / `FAIL` / `UNKNOWN / INCOMPLETE`.

Open `{B3_HOME}/skills/engineering/verification/SKILL.md` (`{B3_HOME}/rules/verification.md`).
