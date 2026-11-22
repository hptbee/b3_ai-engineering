---
name: b3-verify
description: >
  Treat a named claim as a verification problem. Run evidence. Label PASS,
  FAIL, or INCOMPLETE. Use when the user says verify, $b3-verify, or /b3-verify.
  Do not use for design-only discussion.
---

# b3-verify

**Action now:** treat a named claim as a verification problem; execute evidence (prefer `scripts/b3-guard.{ps1,sh} verify-run` / `verify-check` for `b3-verify-v1` receipts) and label `PASS` / `FAIL` / `UNKNOWN / INCOMPLETE`.

Resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, or this repo) and open `{B3_HOME}/skills/engineering/verification/SKILL.md` (`{B3_HOME}/rules/verification.md`).
