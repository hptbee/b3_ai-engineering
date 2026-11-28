# Engineering Philosophy

The governing principle of `b3-ai-engineering` is:

> Maximum Engineering Quality × Maximum Safe Parallelism × Minimum Necessary Context × Minimum Total Cost per Verified Result

Every workflow, skill, subagent dispatch, and optimization is evaluated against verified engineering outcomes per unit of total cost and context—never raw speed, raw agent count, or unverified output.

**Product north star:** Make the coding agents developers already use complete real tasks with less total token/context spend, fewer retries, and less manual correction. Current daily usage spans Cursor, Codex, and Antigravity, with host-neutral adapters including Claude Code; the architecture stays portable for additional coding-agent CLIs. Native Rust checks provide deterministic execution but do not constitute a standalone AI model/agent runtime. See the [canonical roadmap](roadmap.md).

## Precedence

This philosophy operates strictly inside the authority stack in [`precedence.md`](precedence.md) (ranks 1–8 remain unchanged and authoritative):

1. Safety / platform constraints
2. Explicit user request
3. Project / repository requirements
4. Hard rules
5. Strong engineering guidelines
6. Technology-specific guidance
7. Personal preferences
8. Optional suggestions

Lower-ranked optimizations or preferences never override higher-ranked constraints.

## Core Invariants

1. Safety and correctness are non-negotiable.
2. Verification must be evidence-based.
3. Independent review must remain independent.
4. Fail-closed behavior must be preserved.
5. Project requirements and governance take precedence.
6. Agents receive only the minimum necessary context.
7. Optimize total cost, including retries, orchestration, verification, review, and integration.
8. Parallel execution is an optimization, not a quality requirement.
9. Host-neutral architecture must be preserved.
10. Prefer the simplest correct solution over unnecessary abstractions.

## Execution Principle

> Maximum safe parallelism, not maximum agent count: run inline when simple, parallel continuously across verified independent work, and sequential when dependencies, shared state, insufficient isolation, or overhead outweigh concurrency.

In practice:

- **Context minimization:** Load only the smallest relevant skill, diff/delta, or `<=25L` context packet rather than full-repo dumps.
- **Total-cost awareness:** Account for orchestrator coordination, wave checks, retries, verification, independent review, and merge/integration—not just worker build time. Never spawn extra workers unless net throughput or quality justifies the overhead.
- **Continuous dependency-aware dispatch:** Model multi-unit work as a minimal dependency graph; dispatch ready independent units right away and release newly unblocked dependents immediately once prerequisites verify, retaining barriers only for shared integration or commits. On partial ambiguity ([`../workflows/references/clarification-gate.md`](../workflows/references/clarification-gate.md)), Parent isolates only affected workstreams (holding blocked tasks and their dependents) while continuing safe independent discovery or unblocked units without speculative edits; the `96%` threshold is a proportional heuristic that never blocks on score alone when zero actionable material ambiguity remains.
- **Adaptive concurrency:** Scale active workers dynamically by available independent work, context budget, host limits, CPU/memory/rate limits, and cost/throughput benefit rather than fixed `3`/`4` worker caps.
- **4 isolation modes (least-expensive-safe):** Select the lightest safe mode (`SHARED_READ_ONLY` for read-only analysis/review without worktrees, `SHARED_DISJOINT_WRITES` in one worktree only when strictly disjoint and parent-validated, `ISOLATED_WRITES` via verified worktrees when risk or side effects require it, or `SEQUENTIAL` fallback) — never create worktrees for read-only agents or claim stronger isolation than the host enforces.
- **Native-first `b3` CLI & canonical ownership:** Execute deterministic 0-token checks via native `b3` (`b3 guard`, `b3 pr`, `b3 sync`, `b3 install`, `b3 context measure`) and enforce single-source ownership: workers execute bounded units without nested spawning, while the parent orchestrator owns shared state, integration, commits, and external PR mutations.
- **Deterministic tool offloading:** Never spend AI tokens on checks deterministic tools perform reliably — discover and run project-native linters, typecheckers, SAST, dead-code/unused-symbol checks, and scoped safe auto-fixes before verification and AI review using `REUSE` → `FALLBACK` → authorized `BOOTSTRAP` progression ([`../workflows/references/static-analysis.md`](../workflows/references/static-analysis.md)).

## Outcome Before Infrastructure

- **Baseline before claiming savings:** Compare the same host/model/task with and without B3. Measure total tokens, verified completion, wall-clock time, retries, and human interventions. Use `UNKNOWN` for unavailable runtime telemetry; static prompt-byte estimates are not actual bills.
- **Minimize coordination tax:** Extra agents, reviews, context refreshes, and guards must justify their overhead. Inline/no-dispatch is the default when it is the simplest safe option; high-risk independent review still applies when warranted.
- **No speculative runtime rebuild:** Integrate an existing coding-agent host through a minimal capability boundary when a real need arises. Private/custom adapters stay outside the public core.
- **Evidence-gated expansion:** A new layer must pass reproducible end-to-end evaluation and fit one canonical owner before it becomes a permanent part of B3.

## Operational Cross-Links

- **Full delivery lifecycle:** [`../workflows/ship.md`](../workflows/ship.md) (wave isolation, `Context Packet`, verification receipts, sequential commit integration).
- **Research-first delivery:** [`../workflows/research-ship.md`](../workflows/research-ship.md) (unit isolation, provenance gates, single-writer serialization).
- **Subagent dispatch & optional model selection:** [`../workflows/references/dispatch-naming.md`](../workflows/references/dispatch-naming.md).
- **Proportional clarification gate (`96%` heuristic default):** [`../workflows/references/clarification-gate.md`](../workflows/references/clarification-gate.md).
- **Adaptive static analysis & mechanical offloading:** [`../workflows/references/static-analysis.md`](../workflows/references/static-analysis.md).
- **Proposed measurement methodology:** [`evaluation.md`](evaluation.md).
