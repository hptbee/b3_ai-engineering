---
name: b3-refactor
description: "Scoped refactor, dead-code cleanup, or measured performance optimization preserving contracts."
---

# b3-refactor

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, host global fallback, or this repo), infer the requested combination of **Refactor**, **Cleanup**, and **Optimize** — execute **only** the inferred subset, never all three by default — and run as one scoped request reusing `{B3_HOME}/skills/engineering/problem-solving/SKILL.md` and `{B3_HOME}/skills/engineering/verification/SKILL.md`.

- **Dispatch & isolation:** follow `{B3_HOME}/workflows/references/dispatch-naming.md` — run routine small edits inline; use disjoint `SHARED_DISJOINT_WRITES` workers and concurrent `SHARED_READ_ONLY` risk-sensitive review only when scope or risk warrants it.
- **Refactor:** establish relevant behavior and contracts, open `{B3_HOME}/skills/engineering/refactoring/SKILL.md`, make the smallest structural change addressing the named problem, and verify behavior preservation.
- **Cleanup:** prove the target is redundant, unused, or obsolete via `{B3_HOME}/skills/engineering/code-review/references/residue-checklist.md`; check callers, exports, adapters, compatibility requirements, and tests before removal; preserve `INTENTIONAL COMPLEXITY` (security boundaries, compatibility behavior, error handling) when redundancy is unproven.
- **Optimize:** identify the named bottleneck or resource cost, route directly to the matching performance skill (`react-performance`, `nodejs-runtime`, `csharp-async`, `ef-core`, `api-design`, `threejs-performance`, `threejs-resources`, `react-three-fiber`) and `{B3_HOME}/agents/b3-performance-reviewer.md` when warranted (do **not** broaden `refactoring/SKILL.md`), establish a baseline or probe, compare after the change, and clearly label unmeasured improvements or unavailable evidence.
- **Scope & stop boundaries:** preserve public contracts unless the user explicitly expands scope; avoid unrelated feature work, dependency upgrades, or formatting churn. Stop after verification and risk-sensitive review — do **not** automatically start `/b3-audit`, `/b3-review-loop`, or `/b3-ship`.
- **Output:** report what changed, why it improves the named problem, preserved contracts, executed verification evidence, and before/after measurements for performance claims.
