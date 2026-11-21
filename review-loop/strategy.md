# Orchestrator procedure

**Trigger:** `commands/review-loop.md` (or `autodev` Review). Run **review → validate → fix → verify → fresh review** until gate, non-convergence, or cap. Never yield after pass 1.

You are the **orchestrator**: never review+fix in one pass, merge findings, and **alone** declare `PASS` / `FAIL` / `STUCK` / `INCOMPLETE`. **Context rule:** self-sufficient at runtime — do **not** load [`spec.md`](spec.md), [`sizing.md`](sizing.md), [`findings.md`](findings.md), or [`models.md`](models.md) unless disambiguating an edge case.

## Roles & dispatch

| Role | Artifact |
| --- | --- |
| Review (1 pass) | `agents/reviewer.md` → `skills/engineering/code-review/SKILL.md` |
| Specialists | `agents/{security,architecture,performance}-reviewer.md` (`performance` hot-path only) |
| Fix & Verify | `agents/fixer.md` + `skills/engineering/verification/SKILL.md` |

- With subagents: fresh Reviewer per review pass, Fixer per fix pass (read-only specialists may run in parallel). Without subagents: strict hat-change in-session and record the limit.
- **Parent → Subagent:** pass `{base_sha}`, `review_files` (+ `delta_files` on Iter 2+), `approach/T00N.md` path (if any), **active (`OPEN` / unverified `FIXED`) findings only**, and 1-line `closed:` IDs. Never paste file bodies or full historical `findings.md`.
- **Reviewer reply (≤ 25 lines):** `Verdict` + `id | sev | conf | status | location | 1-line issue | evidence_ref` + 1-line checked/skipped dimensions. No prose essays or echoed code blocks.
- **Fixer reply (≤ 20 lines):** `finding_id -> files_touched -> verification_cmd (exit code + 1-line result)`. Keep 1 line on green checks; ≤ 35 failing lines on red or log to `{RUN_DIR}/logs/`.
- **Performance routing:** dispatch `performance-reviewer` **only** on render/animation loops (`useFrame`, Three.js/GPU), large lists/hot serialization, EF/SQL query shape/N+1/pagination, caching/concurrency/event-loop blocking, or latency-sensitive endpoints. Skip (with reason) for copy, docs, CSS, or trivial CRUD. Specialist passes count toward the 12-pass cap.

## 0. Target, size & status map

1. Run `scripts/autodev-guard.ps1 diff-scope -BaseSha <base> [-PrevSha <prev>]` (or `.sh diff-scope --base-sha <base> [--prev-sha <prev>]`; never `HEAD~1`). Empty diff → `UNKNOWN / INCOMPLETE`, stop.
2. **Sizing (`size_class`):** `NOISE_ONLY` (`files=0`, lockfile/generated only → run build/tests; green = `PASS` without LLM review); `SMALL` (≤8f, ≤300L, 1 area) / `MEDIUM` (≤20f, ≤800L, ≤2 areas) → §1 (max **5** iter); `LARGE` (>MEDIUM or ≥3 areas/contracts) / `VERY_LARGE` (≥50f or ≥2000L) → §2.
3. **Finding statuses (`R001`… monotonic, never recycle):** `OPEN` = blocking `CONFIRMED` (`critical`/`high`/`medium`, incl. proven `CONFIRMED REDUNDANCY`); `FIXED` = edited, non-closed until verified (`VERIFIED`/`CLOSED`); `REJECTED` = `FALSE_POSITIVE` (+ reason); `ACCEPTED` = out-of-scope / `INTENTIONAL COMPLEXITY` (+ reason); `SPECULATIVE` = unproven / `LIKELY REDUNDANT` / `UNKNOWN` / `critical+low-conf` (non-blocking — never delete/fix on guesswork).

## 1. SMALL / MEDIUM — full-PR loop (max 5 iterations)

1. **Reviewer:** fresh review of current scope (Iter 2+: inspect `delta_files` + affected callers/contracts first without re-reading untouched files verbatim, plus **fix-cycle residue**: duplicated logic, dead paths, redundant guards, temp wrappers; never narrow to “did we fix R001?” alone). `closed:` IDs block reopening without new evidence.
2. **Orchestrator:** merge & classify findings per §0.3.
3. **Gate:** `PASS` when blocking `OPEN` (`critical`/`high`/`medium`) = **0** AND required build/tests `PASS` (list `LOW`/nits; missing/failed tool run → `UNKNOWN / INCOMPLETE`, never `PASS`).
4. **Stagnation:** stop `STUCK` / `INCOMPLETE` (`REVIEW LOOP DID NOT CONVERGE`) on flat/rising blockers, oscillation, no-op fix, or cap (`FAIL` if `CONFIRMED` blockers remain).
5. **Fixer + Verify:** **before** Fixer, capture `prev_sha` (`autodev-guard snapshot`). Fix `OPEN` `CONFIRMED` items only, run affected checks, then loop to §0.1 (`-PrevSha`/`--prev-sha` `{prev_sha}`) + fresh Reviewer.

## 2. LARGE / VERY_LARGE — unit loops then cross-cut

1. Partition into ≤ **4** cohesive feature/contract units (with tests; never 1-file crumbs). If inseparable, recommend splitting the PR and run §1 or stop `INCOMPLETE`.
2. Per unit (max **3** iterations): pass unit files + interfaces + active unit findings only. Overall cannot `PASS` if any unit stops `STUCK`.
3. **Cross-cutting** (max **2** iterations): boundary interactions only — contracts, data flow, shared types, transactions, error propagation, cross-unit duplication. Total reviewer passes ≤ **12** (exceeding → `STUCK` / `INCOMPLETE`).

## 3. Stop & report

Report compactly: `size_class`, units (if any), iteration blocker counts, active/closed finding summary, verification commands + exit codes, and outcome (`PASS` | `FAIL` | `STUCK` | `INCOMPLETE`).
