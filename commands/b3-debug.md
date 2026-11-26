---
name: b3-debug
description: Investigate root cause of a failure before patching. Use when a bug, test failure, or unexpected behavior needs diagnosis.
---

# b3-debug

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, host global fallback, or this repo), name the broken invariant, test one cheapest hypothesis, sweep confirmed sibling sites, add a regression test, and verify (`verification`).

- **Skills:** `{B3_HOME}/skills/engineering/debugging/SKILL.md`, then `{B3_HOME}/skills/engineering/verification/SKILL.md` after a fix. Stop and escalate after 3 failed hypotheses — never skip to implement-from-guess or drive-by refactors.
- **Model preference:** if the host supports subagents and `.b3/models.md` or `~/.b3/models.md` (`B3_MODELS_PERSONAL`, per `{B3_HOME}/workflows/references/dispatch-naming.md`) sets a non-`auto` `debugging` model differing from `main`, dispatch a debugging subagent on that model (no nested subagents); otherwise diagnose inline on `main`.
