---
name: b3-debug
description: Investigate root cause of a failure before patching. Use when a bug, test failure, or unexpected behavior needs diagnosis.
---

# b3-debug

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, host global fallback, or this repo), name the broken invariant, test hypotheses, sweep confirmed sibling sites, add a regression test, and verify (`b3 guard verify-run`).

- **Skills:** `{B3_HOME}/skills/engineering/debugging/SKILL.md`, then `{B3_HOME}/skills/engineering/verification/SKILL.md` after a fix. Stop and escalate after 3 failed hypotheses — never skip to implement-from-guess or drive-by refactors.
- **Parallel scouts & isolation:** for multi-boundary or ambiguous failures, dispatch concurrent `SHARED_READ_ONLY` root-cause hypothesis and log scouts via `{B3_HOME}/workflows/references/dispatch-naming.md`; cancel/stop redundant scouts once evidence isolates root cause. Serialize conflicting edits and `b3 guard verify-run`.
- **Model routing (independent of parallelism):** scheduling (inline vs concurrent scouts) is decided by failure scope/ambiguity above, never disabled by `model=auto`. Resolve `b3 config get --route debugging` per `dispatch-naming.md`: if the host supports subagents and the routed `debugging` model differs from `main` (non-`auto`), run dispatched debugging subagent(s) (or a read-only diagnosis subagent for single-boundary work, no nested subagents) on that model; when `auto`/unset, keep the chosen inline or parallel schedule on `main`'s model.
