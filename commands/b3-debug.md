---
name: b3-debug
description: Investigate root cause of a failure before patching. Use when a bug, test failure, or unexpected behavior needs diagnosis.
---

# b3-debug

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, or this repo), name the broken invariant, test one cheapest hypothesis, sweep confirmed sibling sites, add a regression test, and verify (`verification`).

**Skill:** `{B3_HOME}/skills/engineering/debugging/SKILL.md`

Then `{B3_HOME}/skills/engineering/verification/SKILL.md` after a fix. Stop and escalate after 3 failed hypotheses — do not skip to implement-from-guess or drive-by refactors.
