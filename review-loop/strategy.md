# Orchestrator procedure

**Trigger:** `commands/b3-review-loop.md` or `/b3-ship` `Review`. Loop **Guard -> Review -> Fix -> Verify -> fresh Review** until gate, `STUCK`, or cap (never stop after pass 1).

You are **orchestrator**: never review+fix in one pass, merge findings, and **alone** emit `PASS`|`FAIL`|`STUCK`|`INCOMPLETE`. Self-sufficient runtime — skip [`spec.md`](spec.md), [`sizing.md`](sizing.md), [`models.md`](models.md) unless disambiguating.

## Roles & dispatch

- Review: `agents/b3-reviewer.md` -> `skills/engineering/code-review/SKILL.md` | Specialists: `agents/b3-{security,architecture,performance}-reviewer.md` | Fix+Verify: `agents/b3-fixer.md` + `skills/engineering/verification/SKILL.md`. On dispatch, load [naming](../agents/dispatch-naming.md) once; request `b3-*` aliases where supported, keep host IDs for resume.
- **Reviewer:** always fresh (distinct from `impl_agent`; parallel read-only specialists ok). **Fix:** resume `impl_agent` with delta findings when present; standalone (no `impl_agent`), dispatch fresh `b3-fixer` with active `OPEN` findings + target files + verify cmd. Without subagents: strict hat-change + log `review_independence: SINGLE_AGENT_LIMIT`.
- **Standalone state (no `/b3-ship` `RUN_DIR`):** save compact `.b3/ship/review-loop/<slug>/` (`state.md`: `base_sha`, `prev_sha`, `size_class`, `iter`, `OPEN`/`FIXED`, `closed:`; `logs/`; `evidence/verify.verify`); resume via `state.md` + `diff-scope -PrevSha` without re-reading untouched code.
- **Parent -> Subagent:** pass `{base_sha}`, `review_files` (+ `delta_files` Iter 2+), `approach/T00N.md` or `state.md`, **active `OPEN`/unverified `FIXED` only**, and `closed:` IDs (no full files/history).
- **Reply caps:** Reviewer <= **25L** (`Verdict` + `id | sev | conf | status | location | issue | evidence_ref` + checked/skipped; no code). Fixer <= **20L** (`id (bug_class) -> files -> verify_cmd (exit + 1L)`; 1L green, <=35L or log on red).
- **Perf routing:** `b3-performance-reviewer` **only** on render/animation loops (`useFrame`/Three.js), large collections/hot serialization, EF/SQL N+1/pagination, cache/concurrency/event-loop blocking, or latency-critical APIs. Counts toward 12-pass cap.

## 0. Target, Guard, size & status

1. Run `b3-guard.{ps1,sh} diff-scope` (`-BaseSha`, optional `-PrevSha`; never `HEAD~1`) + `mechanical-check` (`-BaseSha`, `-AllowedPaths`, `-Obsoletes`) + `symbol-check` on refactors. Empty diff -> `UNKNOWN / INCOMPLETE`. Fix `scope_creep`/`leftovers`/`obsolete_hits` (`exit 2`) before review.
2. **Sizing (`size_class`):** `NOISE_ONLY` (`files=0` + checks green = `PASS`); `SMALL` (<=8f, <=300L, 1 area) / `MEDIUM` (<=20f, <=800L, <=2 areas) -> §1 (max **5** iter); `LARGE` (>MEDIUM or >=3 areas) / `VERY_LARGE` (>=50f or >=2000L) -> §2.
3. **Statuses (`R001`... monotonic):** `OPEN` = blocking `CONFIRMED` (`critical`/`high`/`medium`, incl. `CONFIRMED REDUNDANCY`); `FIXED` = edited, unverified (`VERIFIED`/`CLOSED`); `REJECTED` = `FALSE_POSITIVE` (+ reason); `ACCEPTED` = out-of-scope / `INTENTIONAL COMPLEXITY` (+ reason); `SPECULATIVE` = unproven / `LIKELY REDUNDANT` / `UNKNOWN` / `critical+low-conf` (non-blocking).

## 1. SMALL / MEDIUM — full-PR loop (max 5 iterations)

1. **Reviewer:** fresh review (Iter 2+: inspect `delta_files` + affected callers/contracts first without re-reading untouched code, plus **fix-cycle residue**; never narrow to "did we fix R001?"). `closed:` IDs block reopening without new evidence.
2. **Orchestrator:** merge & classify per §0.3.
3. **Gate:** `PASS` when `OPEN` blockers = **0** AND checks `PASS` on current tree (prefer `b3-guard verify-run`/`verify-check` `b3-verify-v1`; missing/stale/failed -> `UNKNOWN / INCOMPLETE`, never `PASS`).
4. **2-Tier Circuit Breaker:** (a) finding survives **2 rounds** -> rewrite brief/fresh Fixer; (b) same **bug class** recurs **2 consecutive rounds** -> return to `Scope`/design. Stop `STUCK`/`INCOMPLETE` (`REVIEW LOOP DID NOT CONVERGE`) on flat/rising blockers, oscillation, no-op, or cap (`FAIL` if `CONFIRMED` blockers remain).
5. **Fixer + Verify:** **before** Fixer, `prev_sha` (`b3-guard snapshot`). Fix `OPEN` `CONFIRMED` items via bug-class sweep in scope, run `verify-run`/checks, loop to §0.1 (`-PrevSha` `{prev_sha}`) + fresh Reviewer.

## 2. LARGE / VERY_LARGE — unit loops then cross-cut

1. Partition into <= **4** cohesive contract units (with tests; never 1-file crumbs). Inseparable -> recommend PR split and run §1 or `INCOMPLETE`.
2. Per unit (max **3** iter): pass unit files + interfaces + active unit findings only. Any unit `STUCK` blocks `PASS`.
3. **Cross-cutting** (max **2** iter): boundary contracts, data flow, shared types, transactions, error propagation, cross-unit duplication only. Total reviewer passes <= **12** (else `STUCK`/`INCOMPLETE`).

## 3. Stop & report

Compact report: `size_class`, units, iter blocker counts, active/closed findings, verify cmds/exit codes (+ receipt), `review_independence` (`SINGLE_AGENT_LIMIT` if no isolation), outcome (`PASS`|`FAIL`|`STUCK`|`INCOMPLETE`).
