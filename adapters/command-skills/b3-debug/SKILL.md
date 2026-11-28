---
name: b3-debug
description: "Root-cause diagnosis before patching via debugging skill ($b3-debug, /b3-debug). Not for guess-and-patch or /b3-ship."
---

# b3-debug

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, host global fallback, or this repo) and isolate root cause & broken invariant before patching (never guess-and-patch, no unrelated refactors, stop/escalate after 3 failed attempts).

- **Skills:** open `{B3_HOME}/skills/engineering/debugging/SKILL.md` directly (then `{B3_HOME}/skills/engineering/verification/SKILL.md` + `b3 guard verify-run` after a fix).
- **Parallel scouts & isolation:** on multi-boundary failures, run concurrent `SHARED_READ_ONLY` hypothesis/log scouts via `{B3_HOME}/workflows/references/dispatch-naming.md` and stop redundant scouts once evidence isolates root cause; serialize conflicting edits + `b3 guard verify-run`.
- **Model routing (independent of parallelism):** scheduling (inline vs concurrent scouts) is decided by failure scope/ambiguity above, never disabled by `model=auto`. If the host supports subagents and `.b3/config.toml` or `~/.b3/config.toml` (`B3_CONFIG_PERSONAL`, per `dispatch-naming.md`; legacy `models.md` via `b3 config migrate`) sets a non-`auto` `debugging` model differing from `main`, run dispatched debugging subagent(s) (or a read-only diagnosis subagent for single-boundary work, no nested subagents) on that model; when `auto`/unset, keep the chosen inline or parallel schedule on `main`'s model.
