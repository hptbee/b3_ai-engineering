# Decision 015 — Native Guard Event Hooks & Hybrid AI/Deterministic Governance

> **Scope note:** Architectural decision record for event-driven native Rust Guard hooks (`b3 hook`), complementing [`decision-015-evidence-gates-tripwires-and-context-budgets.md`](decision-015-evidence-gates-tripwires-and-context-budgets.md) (which introduced `b3 guard` evidence gates/tripwires and deferred host-specific JS hook daemons) and [`decision-018-research-ship-workflow.md`](decision-018-research-ship-workflow.md).

## Context

B3's deterministic Rust guard (`src/guard/*`) enforces verification receipts, staged-index hygiene, safety tripwires, wave ownership, and merge policy at explicit workflow checkpoints (`/b3-ship`, `/b3-research-ship`, `/b3-review-loop`). However, AI coding sessions also perform ad-hoc tool calls (file writes, shell commands, manual commits/pushes) outside structured workflow steps—or mid-task before the Review/Commit gate runs.

Earlier external audits (`decision-015-evidence-gates-tripwires-and-context-budgets.md`) rejected host-specific JS hook adapters, vector DBs, and background daemons because they violated `rules/portability.md`, duplicated guard logic, and added runtime dependencies. Now that B3's core guard, adapter, and preference layers are consolidated in a single zero-dependency Rust binary (`b3`), event hooks can be supported without daemons, external runtimes, or a second guard engine.

## Options considered

1. **Host-specific JS/Python hook scripts or a persistent background daemon:** Rejected. Adds non-Rust runtime dependencies, duplicates `src/guard/*` path/secret/precommit rules, and introduces daemon lifecycle failure modes.
2. **Workflow-prompt-only enforcement (no event hooks):** Rejected. Costs LLM tokens to remind agents, cannot intercept ad-hoc edits/commits before damage occurs, and misses deterministic tool-boundary fast-fail (`<10 ms`).
3. **Hybrid AI + event-driven native Rust Guard hooks (`b3 hook`) reusing `models.md` + `src/guard/*`:** Selected.

## Decision

**ADOPT option 3 — Hybrid AI + event-driven Rust Guard hooks:**

- **Single canonical guard engine (`src/guard/*`):** `b3 hook` is a thin event-translation layer over existing `src/guard/*` primitives (`precommit`, `merge_policy`, `mechanical`, `scope`, `freshness`, `verify`, `cache`). No guard algorithms are duplicated in shell scripts, JS, or Markdown.
- **No daemon, no subagents, no LLM calls in hooks:** `b3 hook` runs as a short-lived CLI process per event, guards against re-entry with `B3_HOOK_ACTIVE=1`, and reuses `b3-verify-v1` receipts (`B3_VERIFY_RECEIPT` + `get_tree_fingerprint`) rather than re-running tests.
- **Tiered latency separation:**
  - **Tier 0 (`<10 ms`, `0` Git subprocesses):** `BeforeFileWrite`, `BeforeCommand` (secret paths, `.b3/` checkpoint protection, traversal/symlink/linked-worktree pure-FS containment checks, provider-neutral lexical high-risk Git command tripwires).
  - **Tier 1 (operation-boundary):** `BeforeCommit` (always runs canonical `guard::precommit`), `BeforePush`/`BeforeMerge` (canonical trunk `guard::merge_policy` + `parse_pre_push_stdin`, fast skip on non-governed repos), `AfterFileWrite` (advisory staleness signal), `WorkerCompletion`/`TaskCompletion` (advisory/no-op on `continuation_active=true`).
  - **Tier 2 (`WORKFLOW_ONLY`):** Full builds/tests (`verify-run`), `review-inventory`, `review-ledger`, `symbol-check`, `check-wave`, `check-worktree`, `snapshot`, `evidence-check` remain strictly in workflows.
- **Opt-in activation & `models.md` reuse:** Hooks require explicit `b3 hook install` and opt-in `hooks:` configuration (`enabled`, `mode: enforce | audit | off`) inside `~/.b3/models.md` and `<project>/.b3/models.md` (with `B3_HOOK_MODE` / `--mode` overrides and early mode resolution before strict payload parsing). Setting `hooks.mode: off` disables event hooks only and **never** bypasses mandatory workflow `b3 guard` gates.
- **Strict AI Clarification Gate separation:** The AI Requirement Clarification Gate (`96%` confidence threshold in `workflows/references/clarification-gate.md`) stays strictly in AI planning/intake and is **never** implemented in Rust or hooks.

## Consequences & tradeoffs

- **Zero always-on context tax:** `always_on_total` (`15,517 B`) remains untouched; `workflows/references/hook-integration.md` loads strictly on demand and `docs/hooks.md` is `0 B` runtime tokens.
- **Defense-in-depth, not a sandbox or server policy:** Lexical `BeforeCommand` checks cannot defeat shell aliases/indirection, and local `.git/hooks/*` can be bypassed with `--no-verify`; OS sandboxing and server-side branch protection remain authoritative.
- **Honest verification boundary:** Local Git CLI hook execution (`pre-commit`, `pre-push`, `pre-merge-commit`, linked worktrees, `.b3-user` shim chaining) is **`LIVE_CLI_VERIFIED`**, while live IDE hook execution (Cursor, Claude Code, Codex, Antigravity) remains **`NOT_VERIFIED`** until observed in live sessions.
