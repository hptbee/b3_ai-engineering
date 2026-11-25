# Engineering Philosophy

The governing principle of `b3-ai-engineering` is:

> Maximum Engineering Quality × Minimum Necessary Context × Minimum Total Execution Cost per Verified Result

Every workflow, skill, subagent dispatch, and optimization is evaluated against verified engineering outcomes per unit of total cost and context—never raw speed or unverified output.

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

> Parallel by default when independently safe and economically justified; sequential when dependencies, shared state, insufficient isolation, or overhead make parallel inappropriate.

In practice:

- **Context minimization:** Load only the smallest relevant skill, diff/delta, or context packet rather than full-repo dumps.
- **Total-cost awareness:** Account for orchestrator coordination, wave checks, retries, verification, independent review, and merge/integration—not just worker build time.
- **Safe bounded parallelism:** Dispatch parallel workers only when tasks are dependency-free, write/read-disjoint, verified safe, and large enough to amortize orchestration overhead; fall back to sequential execution otherwise.
- **Adaptive least-expensive-safe isolation:** Select the lightest mode that satisfies safety (`SHARED_READ_ONLY` for read-only work, `SHARED_DISJOINT_WRITES` in one worktree only when strictly disjoint and parent-validated, `ISOLATED_WRITES` via verified worktrees when risk or side effects require it, or `SEQUENTIAL` fallback) — never create worktrees for read-only agents or claim stronger isolation than the host enforces.

## Operational Cross-Links

- **Full delivery lifecycle:** [`../workflows/ship.md`](../workflows/ship.md) (wave isolation, `Context Packet`, verification receipts, sequential commit integration).
- **Research-first delivery:** [`../workflows/research-ship.md`](../workflows/research-ship.md) (unit isolation, provenance gates, single-writer serialization).
- **Subagent dispatch & optional model selection:** [`../workflows/references/dispatch-naming.md`](../workflows/references/dispatch-naming.md).
- **Proposed measurement methodology:** [`evaluation.md`](evaluation.md).
