# Decision 016 — Standalone Commands Quality & Context Efficiency Upgrade

## Context

Following Decision 015 (evidence-backed quality gates and `/b3-ship` hardening), auditing the six standalone commands (`/b3-plan`, `/b3-implement`, `/b3-debug`, `/b3-review`, `/b3-review-loop`, `/b3-verify`) revealed remaining gaps:
1. `verify-check` validated core receipt hashes and status but did not require `command`/`log_path`/`timestamp_utc` fields, verify repo-contained existing logs, verify expected command parity (`-ExpectedCmd`), or enforce requested path coverage (`-RelevantPaths`).
2. `commands/b3-implement.md` description included `"ship"` and eagerly directed agents through `workflows/feature-implementation.md` (an avoidable second hop), while `problem-solving/SKILL.md` lacked deterministic guards, risk-sensitive specialist activation, and bounded re-verification.
3. `planning/SKILL.md` needed explicit risk-adaptive depth without inflating small plans; `debugging/SKILL.md` needed an explicit broken invariant, sibling caller sweep, anti-symptom check, regression test requirement, and 3-attempt escalation; `code-review/SKILL.md` needed explicit delta-first bounds and receipt verification; `review-loop/strategy.md` lacked standalone persistence (`.b3/ship/review-loop/<slug>/`), standalone `b3-fixer` dispatch when no `impl_agent` exists, and explicit `SINGLE_AGENT_LIMIT` honesty.
4. `verification/SKILL.md` did not yet integrate `b3-guard verify-run`/`verify-check` provenance verification or dependency-manifest invalidation rules.

## Decision

**ADOPT** the unified standalone command upgrade:
- Extend `b3-guard.{ps1,sh} verify-check` fail-closed provenance (`command`, `log_path` containment + existence, `timestamp_utc`), `-ExpectedCmd`/`--expected-cmd` (`VERIFY_MISMATCH`), and `-RelevantPaths`/`--relevant-paths` (`VERIFY_SCOPE_MISMATCH`) while keeping `precommit -RequireVerifyReceipt` compatible.
- Upgrade all 6 commands, command skills, engineering skills, and `review-loop/strategy.md` using strict single-hop disclosure (keeping `/b3-ship` untouched and zero increase in `always_on_total`).
- Add `standalone_cmds` static load telemetry to `measure-context.{ps1,sh}`, dual-shell sandbox tests in `scripts/validate-standalone-commands.ps1`, and 12 command eval fixtures under `evals/commands/`.

## Consequences & tradeoffs

- **Budget efficiency:** `always_on_total` stays `14940 B` (`0 B` delta), `review-loop/strategy.md` shrinks to `4934 B` (`-363 B`), and single-hop `b3-implement` eliminates loading `workflows/feature-implementation.md` (`1568 B`) on routine implementation requests.
- **State isolation:** `.b3/ship/verify/` and `.b3/ship/review-loop/` share the gitignored `.b3/ship/` exclusion in guards without polluting `diff-scope`, `tree_hash`, or `/b3-ship` `resolve-run`.
- **Limitation:** Host IDE runtime slash-command discovery and macOS Bash 3.2 / Linux `pwsh` remain `UNKNOWN / INCOMPLETE` on Windows.
