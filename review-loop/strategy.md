# Orchestrator procedure

**Trigger:** `commands/b3-review-loop.md` or `/b3-ship` `Review`. Loop **Guard -> Review -> Fix -> Verify -> fresh Review** until gate, `STUCK`, or cap.

**Orchestrator:** never review+fix in 1 pass; merge findings; **alone** emit `PASS`|`FAIL`|`STUCK`|`INCOMPLETE`|`BLOCKED`. Load [`hierarchical.md`](hierarchical.md) only on `L`/`XL`/`XXL`; skip `spec`/`sizing`/`models.md` normally.

## Roles & dispatch (`b3-*` roles only)

- **Lean loads:** [dispatch](../workflows/references/dispatch-naming.md) + `b3 config get --route` **1x/loop**; [context-routing](../workflows/references/context-routing.md) `<=1x/loop` if triggered (`context_hint: tools=native cache=none` skips). Pass 1L `context_hint:`; cache IDs; no nested subagents.
- **Reviewer (`b3-reviewer` + specialists):** fresh, read-only; `agents/b3-reviewer.md` self-contained (skip `code-review/SKILL.md`/`review-template.md`). Fan out in `SHARED_READ_ONLY` (`dispatch-naming.md`); `risk_level` != size:
  - `LOW`: 0-tok checks + 1 `b3-reviewer`.
  - `MEDIUM`: `b3-reviewer` + triggered specialist (`b3-{security,architecture,performance}-reviewer`).
  - `HIGH`: `b3-reviewer` + specialists + contract/dep review.
  - `CRITICAL`: deep review + mandatory specialists (no waiver) + cross-boundary `verify-run`.
- **Fixer:** reuse `impl_agent` until Tier-1 -> `agents/b3-fixer.md` (`verification/SKILL.md` on demand); standalone -> `b3-fixer` (`OPEN`+targets+`verify_cmd`). Disjoint fixes run concurrently via `check-wave --partition` + `mechanical-check` (`dispatch-naming.md`) + re-verify. No subagents: hat-change -> `review_independence: SINGLE_AGENT_LIMIT`.
- **State/replies:** standalone `.b3/ship/review-loop/<slug>/` (`state.md`,`ledger.md`,`logs/`,`verify.verify`; `review-ledger --action normalize`). Reviewer `<=25L`; Fixer `<=20L` (`<=35L`/log red).

## 0. Target, Guard, Size × Risk & Status

1. **Guard:** standalone Iter 1 + Iter 2+ (`--prev-sha`) own `diff-scope` (`--base-sha`; never `HEAD~1`) + `mechanical-check` (`--base-sha`, `--allowed-paths`, `--protected-paths`, `--obsoletes`) + `symbol-check` (refactors); skip Iter-1 if caller passed fresh output on same tree/`HEAD`/scope. Empty->`INCOMPLETE`; `CLEAN_AFTER_FIX`->§1 `delta_files`. Fix/block `exit 2` (`MECHANICAL_FINDINGS`/`SYMBOL_FINDINGS` `dangling_refs`; `safety_hits`->`BLOCKED`; proven FP `dangling_refs` noted). Surface `exit 0` `MECHANICAL_ADVISORY` (`advisory_hits=`)/`SYMBOL_ADVISORY` (`orphan_internal`) to Reviewer w/ native compiler/linter output (no mechanical block).
- **Sizing & iter:** `NOISE_ONLY` (`files=0`+PASS); `review.sizing` (`XS`<=3f,100L;`S`<=8f,300L;`M`<=20f,800L)->**§1** (`max=review.max_iterations`,def 5); (`L`<50f,2k;`XL`<=100f,5k;`XXL`)->**§2**.
3. **Statuses (`R001`..):** `OPEN`=blocking `CONFIRMED` (`CRITICAL|HIGH|MEDIUM`,`CONFIRMED REDUNDANCY`,evidenced overengineering w/ simpler alt meeting reqs—never LOC alone,hot `EVIDENCED RISK`); `FIXED`=unverified (`VERIFIED`/`CLOSED`); `REJECTED`=`FALSE_POSITIVE`; `ACCEPTED`=`INTENTIONAL COMPLEXITY`/OOS; `SPECULATIVE`=unproven/`LOW`-conf/`LIKELY REDUNDANT` (non-blocking); `UNKNOWN`=unproven.

## 1. XS / S / M — full-PR loop (max 5 iterations)

1. **Reviewer:** fresh pass + 1L `context_hint:` — Iter 1 diff-first; Iter 2+ delta-first (`delta_files`+callers+`OPEN`+contracts; never "did we fix R001?"; respect `closed:`). MCP fail -> native fallback, never false `PASS`.
2. **Gate:** skip `verify-check` right after `verify-run` exit `0` w/ 0 edits, else `verify-check` — `OPEN`=0 + `VERIFY_VALID` + risk evidence -> `PASS` (`FAIL` on red check; `UNKNOWN / INCOMPLETE` on bad/stale receipt, tool fail, or `SINGLE_AGENT_LIMIT` on `HIGH`/`CRITICAL`, which cannot emit `PASS` on `HIGH`/`CRITICAL` -> `INCOMPLETE`, blocks `auto_merge`).
3. **Breaker:** (a) finding 2 rounds -> rewrite/fresh `b3-fixer`; (b) bug class 2 rounds -> `Scope`/design. Stop `STUCK`/`INCOMPLETE` on flat/rising blockers, loops, no-op, or cap (`FAIL` if blockers remain).
4. **Fix+Verify:** sole owner of pre-Fix `b3 guard snapshot` (`prev_sha`), sweep `OPEN` by bug class (disjoint via `check-wave --partition`), `verify-run`, loop §0.1 (`--prev-sha`) + fresh Reviewer.

## 2. L / XL / XXL — hierarchical L0–L4 (`hierarchical.md`)

1. `b3 guard review-inventory` (L0; `PARTITION_INCOMPLETE` if unsafe) + `review-ledger --action init` (adaptive `--max-concurrency`, `passes_used`, def `12` L/XL,`24` XXL); advise split if separable; never skip units.
2. **L1–L3:** L1 if `l1_specialists != none` (else `l1_skip_rationale`); L2 `SHARED_READ_ONLY` units (adaptive `dispatch-naming.md`, single-writer ledger, max 3/unit); post-integration L3 cross-unit (max 2) + `verify-run` after parallel code waves.
3. **L4 Gate:** `review-ledger --action check`=`LEDGER_GATE_PASS`; moved ref, stale receipt, missing/oversized unit, bad `CRITICAL` waiver, pass tamper, or cap -> `INCOMPLETE`/`BLOCKED`.

## 3. Stop & report

Report `size_class`+`risk_level`, units/ledger, iters, findings, receipts, skip rationale, `review_independence`, outcome (`PASS|FAIL|STUCK|INCOMPLETE|BLOCKED`). PR post: verified only (`pr-feedback/SKILL.md`).
