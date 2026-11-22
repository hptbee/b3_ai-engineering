# Decision 014 — Parallel disjoint waves, worker cache reuse, mechanical pass, and bug-class sweep

## Context

Following `decision-012` (which deferred parallel multi-WP waves while adopting `/leader` shift-left invariants), a full review of the `ccc-skills` `/leader` Phase 1–5 procedure (2026-11-22) surfaced six high-signal runtime efficiency and defect-prevention mechanisms that complement B3's host-neutral, low-context `/autodev` and `/review-loop` design.

## Options considered

1. Adopt `/leader` verbatim (in-chat `Concept Pack` pasted into every brief, Claude-only `TodoWrite`, parent-as-reviewer full-file reads, mandatory 3-explorer Debate Round).
2. **ADAPT** the portable, context-saving mechanisms into B3's file-backed checkpoints, CLI guard (`0 LLM tokens`), and independent-reviewer architecture, while **REJECT**ing context-multiplying and host-locked pieces.

## Decision

**ADOPT option 2.**

### ADAPT

- **Deterministic Mechanical Pass (`autodev-guard mechanical-check`, `0 LLM tokens`):** Run `scope_creep` (against `AllowedPaths`), added-line `leftovers` (`debugger`, `.only(`, `@ts-ignore`, `eslint-disable`, empty `TODO`/`FIXME` on non-`.md` files), and `obsolete_hits` (`exists` / `git grep`) before spending LLM review tokens.
- **Worker prompt-cache reuse (`impl_agent` in `progress.md` + delta resume):** Record `impl_agent` in `{RUN_DIR}/progress.md` (`## Tasks` table, host-neutral replacement for `TodoWrite`) and resume the owning worker with delta findings/contract diffs on Fix passes while keeping **Reviewer** strictly fresh and independent.
- **Bug-class sweep & replacement rule (`agents/fixer.md`):** Name 1-line broken invariant per finding, sweep sibling sites strictly inside `OWNED FILES`/`DIFF SCOPE` (reporting unowned sites without expanding scope), add/update a behavior test when applicable, and delete replaced/renamed symbols once unused.
- **2-tier circuit breaker (`review-loop/strategy.md`):** (a) same finding survives 2 rounds → rewrite brief or spawn a fresh Fixer (drop stale `impl_agent`); (b) same bug class recurs 2 consecutive rounds → stop patching and return to `Analyze`/design.
- **Optional disjoint-file Parallel Waves + Hub-and-Spoke (`workflows/autonomous-development.md`):** Allow launching 2–3 `ready` tasks in one message when `autodev-guard check-wave` proves disjoint `OWNED FILES` (exact + prefix + repo-root `.`), paste shared contracts verbatim (never paraphrased), enforce scoped `VERIFY` (no pipe exit-code swallowing; fix only self-caused failures in owned files; report unowned/baseline failures), relay `discoveries`/`change_requests` solely through Parent, and keep atomic sequential per-task commits.
- **Contrarian lens (`agents/architecture-reviewer.md`, `design-only`):** Challenge assumptions and propose simpler designs eliminating a whole bug class (e.g., 1 shared write helper instead of N paths; parser/allowlist instead of regex/denylist) without spawning 3 explorers + a Debate Round.

### REJECT

- `Concept Pack in chat and briefs, never a file` (multiplies input tokens across workers/reviewers and loses state on `/compact`; B3 keeps `{RUN_DIR}/` file paths).
- Claude-specific `TodoWrite` for agent tracking (replaced by `{RUN_DIR}/progress.md` `impl_agent` column).
- Parent reading full changed files as primary reviewer (bloats orchestrator context; B3 keeps isolated `agents/reviewer.md` subagents with `<= 25`-line replies).

## Consequences

- Mechanical defect detection and wave safety become deterministic zero-token CLI checks (`autodev-guard.{ps1,sh}`).
- Fix iterations preserve worker prompt cache and eliminate sibling defects in fewer rounds while preserving independent review and strict static context budgets (`measure-context -Strict`).
- Live multi-worker parallel wave execution across all 4 hosts remains `UNKNOWN / INCOMPLETE` until exercised on a multi-package product repo.

## Confidence

High on CLI parity, workflow invariants, and static context budgets (verified by `validate-autodev-behavior.ps1`, `measure-context.{ps1,sh}`, and `validate-evals.sh`); live cross-host parallel wave UX remains `UNKNOWN / INCOMPLETE`.
