# Orchestrator procedure

**Trigger:** `commands/b3-review-loop.md` (or `/b3-ship` `Review`). Run **Guard → Review → Fix → Verify → fresh Review** until gate, non-convergence, or cap. Never yield after pass 1.

You are the **orchestrator**: never review+fix in one pass, merge findings, and **alone** declare `PASS` / `FAIL` / `STUCK` / `INCOMPLETE`. **Context rule:** self-sufficient at runtime — skip [`spec.md`](spec.md), [`sizing.md`](sizing.md), [`models.md`](models.md) unless disambiguating an edge case.

## Roles & dispatch

| Role | Artifact |
| --- | --- |
| Review (1 pass) | `agents/b3-reviewer.md` → `skills/engineering/code-review/SKILL.md` |
| Specialists | `agents/b3-{security,architecture,performance}-reviewer.md` (`performance` hot-path only) |
| Fix & Verify | `agents/b3-fixer.md` + `skills/engineering/verification/SKILL.md` |

- With subagents: **always** dispatch a fresh independent Reviewer (distinct from `impl_agent`; read-only specialists may run in parallel). For Fix passes, **resume the owning `impl_agent`** with delta findings (preserving prompt cache); spawn a fresh Fixer only for unowned files or circuit-breaker resets. Without subagents: strict hat-change and log the limit.
- **Parent → Subagent:** pass `{base_sha}`, `review_files` (+ `delta_files` on Iter 2+), `approach/T00N.md` path, **active (`OPEN` / unverified `FIXED`) findings only**, and `closed:` IDs. Never paste file bodies or full `findings.md`.
- **Reply caps:** Reviewer ≤ **25 lines** (`Verdict` + `id | sev | conf | status | location | 1-line issue | evidence_ref` + checked/skipped dimensions; no echoed code). Fixer ≤ **20 lines** (`finding_id (bug_class) -> files_touched -> verification_cmd (exit + 1-line)`; 1 line on green, ≤ 35 failing lines on red or log to `{RUN_DIR}/logs/`).
- **Performance routing:** dispatch `b3-performance-reviewer` **only** on render/animation loops (`useFrame`/Three.js), large lists/hot serialization, EF/SQL N+1/pagination, caching/concurrency/event-loop blocking, or latency-sensitive endpoints (skip copy/docs/CSS/trivial CRUD). Specialist passes count toward the 12-pass cap.

## 0. Target, Guard, size & status

1. Run `b3-guard.{ps1,sh} diff-scope` (`-BaseSha`/`--base-sha`, optional `-PrevSha`/`--prev-sha`; never `HEAD~1`) + `mechanical-check` (`-BaseSha`/`--base-sha`, optional `-AllowedPaths`, `-Obsoletes`). Empty diff → `UNKNOWN / INCOMPLETE`. Fix `scope_creep`/`leftovers`/`obsolete_hits` (`exit 2`) before LLM review.
2. **Sizing (`size_class`):** `NOISE_ONLY` (`files=0` → build/tests green = `PASS`, skip LLM review); `SMALL` (≤8f, ≤300L, 1 area) / `MEDIUM` (≤20f, ≤800L, ≤2 areas) → §1 (max **5** iter); `LARGE` (>MEDIUM or ≥3 areas/contracts) / `VERY_LARGE` (≥50f or ≥2000L) → §2.
3. **Statuses (`R001`… monotonic):** `OPEN` = blocking `CONFIRMED` (`critical`/`high`/`medium`, incl. `CONFIRMED REDUNDANCY`); `FIXED` = edited, unverified (`VERIFIED`/`CLOSED`); `REJECTED` = `FALSE_POSITIVE` (+ reason); `ACCEPTED` = out-of-scope / `INTENTIONAL COMPLEXITY` (+ reason); `SPECULATIVE` = unproven / `LIKELY REDUNDANT` / `UNKNOWN` / `critical+low-conf` (non-blocking).

## 1. SMALL / MEDIUM — full-PR loop (max 5 iterations)

1. **Reviewer:** fresh review (Iter 2+: inspect `delta_files` + affected callers/contracts first without re-reading untouched files, plus **fix-cycle residue**: duplicated logic, dead paths, redundant guards, temp wrappers; never narrow to “did we fix R001?”). `closed:` IDs block reopening without new evidence.
2. **Orchestrator:** merge & classify per §0.3.
3. **Gate:** `PASS` when blocking `OPEN` (`critical`/`high`/`medium`) = **0** AND required build/tests `PASS` (list `LOW`/nits; missing/failed check → `UNKNOWN / INCOMPLETE`, never `PASS`).
4. **2-Tier Circuit Breaker:** (a) same finding survives **2 rounds** → rewrite fix brief or spawn fresh Fixer (drop stale `impl_agent`); (b) same **bug class** recurs **2 consecutive rounds** → design flaw: stop patching, return to `Scope`/design. Stop `STUCK`/`INCOMPLETE` (`REVIEW LOOP DID NOT CONVERGE`) on flat/rising blockers, oscillation, no-op fix, or cap (`FAIL` if `CONFIRMED` blockers remain).
5. **Fixer + Verify:** **before** Fixer, capture `prev_sha` (`b3-guard snapshot`). Fix `OPEN` `CONFIRMED` items via bug-class sweep inside `OWNED FILES`/`DIFF SCOPE`, run affected checks, then loop to §0.1 (`-PrevSha`/`--prev-sha` `{prev_sha}`) + fresh Reviewer.

## 2. LARGE / VERY_LARGE — unit loops then cross-cut

1. Partition into ≤ **4** cohesive feature/contract units (with tests; never 1-file crumbs). If inseparable, recommend splitting the PR and run §1 or stop `INCOMPLETE`.
2. Per unit (max **3** iterations): pass unit files + interfaces + active unit findings only. Overall cannot `PASS` if any unit stops `STUCK`.
3. **Cross-cutting** (max **2** iterations): boundary interactions only — contracts, data flow, shared types, transactions, error propagation, cross-unit duplication. Total reviewer passes ≤ **12** (exceeding → `STUCK` / `INCOMPLETE`).

## 3. Stop & report

Report compactly: `size_class`, units (if any), iteration blocker counts, active/closed finding summary, verification commands + exit codes, and outcome (`PASS` | `FAIL` | `STUCK` | `INCOMPLETE`).
