---
name: b3-audit
description: "Read-only baseline review of a repo, subsystem, or component including unchanged files ($b3-audit, /b3-audit). Not for diff/PR /b3-review or auto-fix."
---

# b3-audit

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, host global fallback, or this repo) and execute a read-only baseline audit using `{B3_HOME}/skills/engineering/code-review/references/baseline-audit.md` and `{B3_HOME}/skills/engineering/code-review/references/review-template.md` (with `{B3_HOME}/skills/engineering/code-review/SKILL.md` and matched domain/specialist roles on demand):
- **Baseline vs `/b3-review`:** inspect existing unchanged files in the target repo, subsystem, directory, or component (empty diff OK); reserve `/b3-review` for Git diffs and PRs. Never fabricate a whole-repo diff or treat `EMPTY_DIFF` / `NOISE_ONLY` / unrelated passing checks as `PASS`.
- **Honest scope & checks:** record `HEAD` SHA / branch and working-tree state; report missing, empty, or inaccessible targets as `UNKNOWN / INCOMPLETE` (never `PASS`), never claim whole-repo cleanliness from a subset, and run only non-mutating checks or read-only `b3 guard verify-check` where semantics match the target.
- **Proportional `SHARED_READ_ONLY` review:** select relevant dimensions only; partition larger scopes by subsystem via `{B3_HOME}/workflows/references/dispatch-naming.md` (`b3-reviewer`, `b3-{security,architecture,performance}-reviewer`), continuing independent subsystems if one blocks and reporting `SINGLE_AGENT_LIMIT` / `UNKNOWN` when isolation is unavailable.
- **Read-only stop:** output template-compliant findings (`CONFIRMED|SPECULATIVE`), coverage limits, and prioritized repair plan (defects vs optional improvements) without writing receipts/logs (`b3 guard verify-run`) or `.b3/` workflow state, editing, committing, or publishing; route requested fixes to `/b3-implement` or `/b3-ship`.
