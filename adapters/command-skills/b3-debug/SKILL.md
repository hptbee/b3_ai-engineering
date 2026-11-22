---
name: b3-debug
description: >
  Investigate root cause of a failure before patching. Use when a bug, test
  failure, or unexpected behavior needs diagnosis, or the user says $b3-debug
  or /b3-debug. Do not skip to implement-from-guess.
---

# b3-debug

**Action now:** isolate root cause & broken invariant before patching (never guess-and-patch, no unrelated refactors, stop/escalate after 3 failed attempts).

Resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, or this repo) and open `{B3_HOME}/skills/engineering/debugging/SKILL.md` directly (then `{B3_HOME}/skills/engineering/verification/SKILL.md` after a fix).
