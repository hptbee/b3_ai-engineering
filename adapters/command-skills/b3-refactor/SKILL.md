---
name: b3-refactor
description: "Scoped refactor, cleanup, or measured optimization ($b3-refactor, /b3-refactor). Reuses impl/perf skills; not for /b3-ship or /b3-audit."
---

# b3-refactor

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, host global fallback, or this repo), infer the requested subset of **Refactor**, **Cleanup**, and **Optimize** (never run unrequested modes), and execute as one scoped request reusing `{B3_HOME}/skills/engineering/problem-solving/SKILL.md` + `{B3_HOME}/skills/engineering/verification/SKILL.md` via `{B3_HOME}/workflows/references/dispatch-naming.md` (inline for small edits; disjoint `SHARED_DISJOINT_WRITES` workers and `SHARED_READ_ONLY` risk-sensitive review when scope/risk warrants).

- **Refactor:** establish contracts, open `{B3_HOME}/skills/engineering/refactoring/SKILL.md`, apply the smallest structural fix, and verify behavior preservation.
- **Cleanup:** prove redundancy via `{B3_HOME}/skills/engineering/code-review/references/residue-checklist.md` (callers, exports, adapters, compatibility, tests); preserve `INTENTIONAL COMPLEXITY` when unproven.
- **Optimize:** route to the matching performance skill (`react-performance`, `nodejs-runtime`, `csharp-async`, `ef-core`, `api-design`, `threejs-performance`, `threejs-resources`, `react-three-fiber`) and `{B3_HOME}/agents/b3-performance-reviewer.md` when warranted (never broaden `refactoring/SKILL.md`); measure baseline vs after, labeling unmeasured claims or missing evidence.
- **Stop & report:** preserve public contracts unless explicitly expanded; skip unrelated features, dependency bumps, or formatting churn; stop after verification and risk-sensitive review (never start `/b3-audit`, `/b3-review-loop`, or `/b3-ship`); report changes, rationale, preserved contracts, verification evidence, and before/after metrics.
