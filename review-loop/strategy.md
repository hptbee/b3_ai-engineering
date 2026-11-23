# Orchestrator procedure

**Trigger:** `commands/b3-review-loop.md` or `/b3-ship` `Review`. Loop **Guard -> Review -> Fix -> Verify -> fresh Review** until gate, `STUCK`, or cap (never stop after pass 1).

You are **orchestrator**: never review+fix in one pass, merge findings, and **alone** emit `PASS`|`FAIL`|`STUCK`|`INCOMPLETE`. Self-sufficient runtime — skip [`spec.md`](spec.md), [`sizing.md`](sizing.md), [`models.md`](models.md) unless disambiguating.

## Roles & dispatch

- **Lean loads & caching:** load [dispatch](../workflows/references/dispatch-naming.md) + optional `.b3/models.md` / `~/.b3/models.md` **once per loop** (apply preference only if host supports, else inherit native; skip Iter 2+). Request `b3-*` aliases; store host IDs for resume.
- **Reviewer:** always fresh (distinct from `impl_agent`). Run `agents/b3-reviewer.md` **self-contained** (skip `code-review/SKILL.md` & `review-template.md`); add parallel `agents/b3-{security,architecture,performance}-reviewer.md` **only** when triggered (perf on hot paths only: `useFrame`/Three.js, large collections/hot serialization, EF/SQL N+1/pagination, cache/concurrency/blocking, latency-critical APIs). **Low-risk fast path:** `SMALL` with zero auth/security/schema/hot-path/architecture triggers -> 1 `b3-reviewer` only (no specialists).
- **Fixer:** reuse `impl_agent` (or cached `fixer_agent` ID) across rounds until Tier-1 breaker forces fresh `agents/b3-fixer.md` (`verification/SKILL.md` on demand only — skip with explicit `verify_cmd`); standalone (no `impl_agent`) -> dispatch fresh `b3-fixer` with `OPEN` findings + target files + `verify_cmd`. Without subagents: strict hat-change + log `review_independence: SINGLE_AGENT_LIMIT`.
- **Standalone state (no `/b3-ship` `RUN_DIR`):** compact `.b3/ship/review-loop/<slug>/` (`state.md`: `base_sha`, `prev_sha`, `size_class`, `iter`, `fixer_agent`, `OPEN`/`FIXED`, `closed:`; `logs/`; `evidence/verify.verify`); resume via `state.md` + `diff-scope -PrevSha` without re-reading untouched code.
- **Parent -> Subagent & caps:** pass `{base_sha}`, `review_files` (+ `delta_files` Iter 2+), `approach/T00N.md` or `state.md`, **active `OPEN`/unverified `FIXED` only**, and `closed:` IDs (no full files/history). Replies: Reviewer <= **25L** (`Verdict` + table + checked/skipped; no code); Fixer <= **20L** (`id (bug_class) -> files -> verify_cmd`; 1L green, <=35L/log on red).

## 0. Target, Guard, size & status

1. Run `b3-guard.{ps1,sh} diff-scope` (`-BaseSha`, optional `-PrevSha`; never `HEAD~1`) + `mechanical-check` (`-BaseSha`, `-AllowedPaths`, `-Obsoletes`) + `symbol-check` on refactors. Empty first-pass diff -> `UNKNOWN / INCOMPLETE`; `CLEAN_AFTER_FIX` (valid `prev_sha` + nonempty `delta_files`) reviews removed changes and requires verified current tree before `PASS`. Fix `scope_creep`/`leftovers`/`obsolete_hits` (`exit 2`) before review.
2. **Sizing (`size_class`):** `NOISE_ONLY` (`files=0` + valid checks = `PASS`); `CLEAN_AFTER_FIX` (zero current diff after fixer) -> §1 on `delta_files`; `SMALL` (<=8f, <=300L, 1 area) / `MEDIUM` (<=20f, <=800L, <=2 areas) -> §1 (max **5** iter); `LARGE` (>MEDIUM or >=3 areas) / `VERY_LARGE` (>=50f or >=2000L) -> §2.
3. **Statuses (`R001`... monotonic):** `OPEN` = blocking `CONFIRMED` (`CRITICAL`/`HIGH`/`MEDIUM`, incl. `CONFIRMED REDUNDANCY` and hot-path `EVIDENCED RISK`); `FIXED` = edited, unverified (`VERIFIED`/`CLOSED`); `REJECTED` = `FALSE_POSITIVE` (+ reason); `ACCEPTED` = out-of-scope / `INTENTIONAL COMPLEXITY` (+ reason); `SPECULATIVE` = unproven / `LOW`-confidence / `LIKELY REDUNDANT` / `UNKNOWN` (non-blocking).

## 1. SMALL / MEDIUM — full-PR loop (max 5 iterations)

1. **Reviewer:** fresh review (Iter 2+: inspect `delta_files` + affected callers/contracts first without re-reading untouched code, plus **fix-cycle residue**; never narrow to "did we fix R001?"). `closed:` IDs block reopening without new evidence.
2. **Orchestrator:** merge & classify per §0.3.
3. **Gate:** check `b3-guard verify-check` first — if `OPEN` blockers = **0** AND `VERIFY_VALID` on current tree, emit `PASS` directly (`FAIL` on failed check; `UNKNOWN / INCOMPLETE` on missing/stale receipt or tool failure, never `PASS`).
4. **2-Tier Circuit Breaker:** (a) finding survives **2 rounds** -> rewrite brief/fresh `b3-fixer`; (b) same **bug class** recurs **2 consecutive rounds** -> return to `Scope`/design. Stop `STUCK`/`INCOMPLETE` (`REVIEW LOOP DID NOT CONVERGE`) on flat/rising blockers, oscillation, no-op, or cap (`FAIL` if `CONFIRMED` blockers remain).
5. **Fixer + Verify:** **before** Fixer, `prev_sha` (`b3-guard snapshot`). Fix `OPEN` `CONFIRMED` items via bug-class sweep in scope, run `verify-run`, loop to §0.1 (`-PrevSha` `{prev_sha}`) + fresh Reviewer.

## 2. LARGE / VERY_LARGE — unit loops then cross-cut

1. Partition into <= **4** cohesive contract units (with tests; never 1-file crumbs). Inseparable -> recommend PR split and run §1 or `INCOMPLETE`.
2. Per unit (max **3** iter): pass unit files + interfaces + active unit findings only. Any unit `STUCK` blocks `PASS`.
3. **Cross-cutting** (max **2** iter): boundary contracts, data flow, shared types, transactions, error propagation, cross-unit duplication only. Total reviewer passes <= **12** (else `STUCK`/`INCOMPLETE`).

## 3. Stop & report

Compact report: `size_class`, units, iter blocker counts, active/closed findings, verify cmds/exit codes (+ receipt), `review_independence` (`SINGLE_AGENT_LIMIT` if no isolation), outcome (`PASS`|`FAIL`|`STUCK`|`INCOMPLETE`).
