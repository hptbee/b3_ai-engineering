# Orchestrator procedure

**Trigger once:** `commands/review-loop.md`. Run **review → validate → fix → verify → fresh review** until quality gate, non-convergence, or iteration cap. Do not yield after the first review.

You are the **orchestrator**. Do not review and fix in the same pass. Dispatch roles, merge the finding log, and **alone** declare `PASS` / `INCOMPLETE` / `STUCK` / STOP. Normative contract: [`spec.md`](spec.md).

## Roles & dispatch

| Role | Artifact |
| --- | --- |
| Review (one pass) | `agents/reviewer.md` → `skills/engineering/code-review` |
| Security / Architecture / Perf depth | `agents/security-reviewer.md`, `agents/architecture-reviewer.md`, `agents/performance-reviewer.md` (hot-path only) |
| Fix | `agents/fixer.md` |
| Evidence / Sizing / Findings / Slots | `skills/engineering/verification`, [`sizing.md`](sizing.md), [`findings.md`](findings.md), [`models.md`](models.md) |

1. With host subagents: dispatch fresh Reviewer per review pass and Fixer per fix pass (read-only specialists may run in parallel with Reviewer). Without subagents: hat-change in-session with the same prohibitions and record the limit.
2. After every Fixer pass, dispatch Reviewer on the **current** implementation (never “did we fix R001?” as the whole review). Reviewer and Fixer never declare loop outcomes.

### Compact handoff & reply contract (context budget)

- **Parent → Subagent:** pass `{base_sha}`, `diff-scope` file list, `approach/T00N.md` path (if any), and **only active (`OPEN` / unverified `FIXED`) findings for that scope** plus a 1-line `closed:` ID list (never paste whole files or full historical `findings.md`).
- **Reviewer reply (≤ 25 lines):** compact table `id | sev | conf | status | location | 1-line issue | evidence_ref` + checked/skipped dimensions. No prose summaries or echoed code blocks.
- **Fixer reply (≤ 20 lines):** `finding_id -> files_touched -> verification_cmd (exit code + 1-line result)`. On passing tests keep summary line only; on failure keep only the failing assertion slice (~30–40 lines) or log to `.b3/autodev/logs/`.

### Performance routing

Dispatch `performance-reviewer` **only** when the diff touches: render/animation loops (`useFrame`, Three.js/GPU), large lists/hot serialization, EF/SQL query shape/N+1/pagination, caching/concurrency/event-loop blocking, or known latency-sensitive request paths. Skip (and record skip) for copy, docs, CSS, or trivial CRUD. Specialist passes count toward the reviewer-pass budget.

## 0. Establish target & size

1. Run `scripts/autodev-guard.{ps1,sh} diff-scope` (or `git diff` against PR base / `{task_base}` / `{run_base_sha}` plus staged, unstaged, untracked non-ignored files; never substitute `HEAD~1`). Exclude lockfile/generated noise from diff text while keeping `noise_files` listed. Empty target → `UNKNOWN / INCOMPLETE`, stop.
2. Use `size_class` ([`sizing.md`](sizing.md)) and initialize the finding log ([`findings.md`](findings.md), stable `R001`…).

## 1. SMALL / MEDIUM — full-PR loop (max 5 iterations)

Do not partition. Per iteration:
1. **Reviewer:** fresh review of current diff (check bugs, regressions, edge cases, missing tests, and **fix-cycle residue**: duplicated logic, obsolete paths, redundant guards/state, temporary wrappers, stale comments). Previous IDs are supplied only to prevent reopening `CLOSED` items without new evidence.
2. **Orchestrator:** merge findings; classify before fixing:
   - Valid, in-scope, concrete (`CONFIRMED` or `CONFIRMED REDUNDANCY`) → Fix (minimal).
   - Invalid → `REJECTED` + reason; Already handled → `CLOSED`; Out of scope / `INTENTIONAL COMPLEXITY` → `ACCEPTED` + reason; Nit → `LOW` (non-blocking); Hypothetical / `LIKELY REDUNDANT` / `UNKNOWN` → `SPECULATIVE` (do not fix/delete without proof).
3. **Gate check:** `PASS` when `critical = 0 AND high = 0 AND medium = 0` AND required build/tests `PASS` (list leftover `LOW`/nits; missing tool evidence → `INCOMPLETE`, never `PASS`).
4. **Stagnation check:** stop `STUCK` / `INCOMPLETE` (`REVIEW LOOP DID NOT CONVERGE`) on flat/rising blocker counts (`4 → 4 → 4`, `5 → 5 → 6`), oscillation, no-op fix, or cap reached (`FAIL` if `CONFIRMED` blockers remain).
5. **Fixer + Verify:** fix only `CONFIRMED` in-scope items, re-run affected build/tests, then loop to fresh Reviewer.

## 2. LARGE / VERY_LARGE — unit loops then cross-cut

1. Partition into ≤ **4** logical review units (feature/architectural boundary, not single-class crumbs). If too coupled to split safely, report “split the PR” and run MEDIUM loop or stop `INCOMPLETE`.
2. Per unit: max **3** iterations; Reviewer sees unit diff + interfaces/deps + active unit findings (never re-send full PR per unit). Advance when unit passes gate or hits `STUCK` (overall cannot `PASS` if any unit is `STUCK`).
3. **Cross-cutting review** (max **2** iterations after units): interactions only — contracts, data flow, shared types, transactions, error propagation, cross-task duplication, integration tests.
4. **Budget cap:** total reviewer passes ≤ **12** (exceeding → `STUCK` / `INCOMPLETE`).

## 3. Stop & report

Report: `size_class`, units (if any), iteration blocker counts, active/closed finding table, verification commands + results, and stop reason (`PASS` | `STUCK` | `INCOMPLETE`).
