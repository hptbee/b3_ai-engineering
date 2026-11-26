---
name: b3-debug
description: Explicit command wrapper ($b3-debug, /b3-debug, b3-debug) for root-cause diagnosis before patching via debugging skill. Not for guess-and-patch or /b3-ship.
---

# b3-debug

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, host global fallback, or this repo) and isolate root cause & broken invariant before patching (never guess-and-patch, no unrelated refactors, stop/escalate after 3 failed attempts).

- **Skills:** open `{B3_HOME}/skills/engineering/debugging/SKILL.md` directly (then `{B3_HOME}/skills/engineering/verification/SKILL.md` after a fix).
- **Model preference:** if the host supports subagents and `.b3/models.md` or `~/.b3/models.md` (`B3_MODELS_PERSONAL`, per `{B3_HOME}/workflows/references/dispatch-naming.md`) sets a non-`auto` `debugging` model differing from `main`, dispatch a debugging subagent on that model (no nested subagents); otherwise diagnose inline on `main`.
