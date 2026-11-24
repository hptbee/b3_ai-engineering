# Orchestrator procedure

**Trigger:** `commands/b3-review-loop.md` or `/b3-ship` `Review`. Loop **Guard -> Review -> Fix -> Verify -> fresh Review** until gate, `STUCK`, or cap (never stop after pass 1).

You are **orchestrator**: never review+fix in one pass, merge findings, and **alone** emit `PASS`|`FAIL`|`STUCK`|`INCOMPLETE`|`BLOCKED`. Self-sufficient runtime — load [`hierarchical.md`](hierarchical.md) **only on `L`/`XL`/`XXL`**; skip `spec.md`, `sizing.md`, `models.md` unless disambiguating.

## Roles & dispatch (Risk-based, existing `b3-*` roles only)

- **Lean loads:** load [dispatch](../workflows/references/dispatch-naming.md) + optional `.b3/models.md` / `~/.b3/models.md` **once per loop** (host-supported preferences only). Cache host IDs.
- **Reviewer (`b3-reviewer` + selective specialists):** always fresh & read-only. Run `agents/b3-reviewer.md` self-contained (skip `code-review/SKILL.md` & `review-template.md`). Evaluate `risk_level` separately from size (`XS` auth = `CRITICAL`; `XXL` docs = `LOW`; never infer risk from LOC alone):
  - `LOW`: 0-tok checks + 1 fresh `b3-reviewer` only (skip specialists).
  - `MEDIUM`: `b3-reviewer` + triggered specialist only (`b3-{security,architecture,performance}-reviewer`).
  - `HIGH`: `b3-reviewer` + matching specialists + affected-contract/dependency review.
  - `CRITICAL`: independent deep review + mandatory matching specialists (self-declared waivers rejected) + cross-boundary `verify-run` receipt.
- **Fixer:** reuse `impl_agent` (`fixer_agent` cache) until Tier-1 breaker forces fresh `agents/b3-fixer.md` (`verification/SKILL.md` on demand only); standalone -> dispatch fresh `b3-fixer` with `OPEN` items + target files + `verify_cmd`. Without subagents: strict hat-change + log `review_independence: SINGLE_AGENT_LIMIT`.
- **State & replies:** standalone runs use `.b3/ship/review-loop/<slug>/` (`state.md`, `ledger.md`, `logs/`, `evidence/verify.verify`); normalize legacy `SMALL|MEDIUM|LARGE|VERY_LARGE` via `review-ledger normalize`. Replies: Reviewer <= **25L** (`Verdict` + table + checked/skipped); Fixer <= **20L** (`id (bug_class) -> files -> verify_cmd`; 1L green, <=35L/log red).

## 0. Target, Guard, Size × Risk & Status

1. Run `b3-guard.{ps1,sh} diff-scope` (`-BaseSha`, optional `-PrevSha`; never `HEAD~1`) + `mechanical-check` (`-BaseSha`, `-AllowedPaths`, `-Obsoletes`) + `symbol-check` on refactors. Initial empty diff -> `INCOMPLETE`; `CLEAN_AFTER_FIX` -> §1 on `delta_files`. Fix `exit 2` hits first.
2. **Sizing & Routing:** `NOISE_ONLY` (`files=0` + valid checks + generated provenance ok = `PASS`); smallest T-shirt tier satisfying BOTH limits (`XS` `<=3f,<=100L`; `S` `<=8f,<=300L`; `M` `<=20f,<=800L`) -> **§1** (max **5** iter); (`L` `<50f,<2000L`; `XL` `<=100f,<=5000L`; `XXL` larger, dynamic units) -> **§2** (`hierarchical.md`).
3. **Statuses (`R001`...):** `OPEN` = blocking `CONFIRMED` (`CRITICAL|HIGH|MEDIUM`, incl. `CONFIRMED REDUNDANCY` and hot-path `EVIDENCED RISK`); `FIXED` = edited, unverified (`VERIFIED`/`CLOSED`); `REJECTED` = `FALSE_POSITIVE` (+ reason); `ACCEPTED` = `INTENTIONAL COMPLEXITY` / out-of-scope (+ reason); `SPECULATIVE` = unproven/`LOW`-conf/`LIKELY REDUNDANT` (non-blocking).

## 1. XS / S / M — full-PR loop (max 5 iterations)

1. **Reviewer:** fresh pass (Iter 2+: `delta_files` + callers + residue; never "did we fix R001?"; respect `closed:`).
2. **Gate:** `b3-guard verify-check` first — if `OPEN` blockers = **0** AND `VERIFY_VALID` on current tree (and required risk evidence present), emit `PASS` (`FAIL` on failed check; `UNKNOWN / INCOMPLETE` on missing/stale/corrupt receipt or tool error).
3. **2-Tier Breaker:** (a) finding survives **2 rounds** -> rewrite brief/fresh `b3-fixer`; (b) same **bug class** recurs **2 rounds** -> return to `Scope`/design. Stop `STUCK`/`INCOMPLETE` on flat/rising blockers, oscillation, no-op, or cap (`FAIL` if `CONFIRMED` blockers remain).
4. **Fixer + Verify:** **before** Fixer, `prev_sha` (`b3-guard snapshot`; fails closed on secrets/dirty submodules). Fix `OPEN` items via bug-class sweep, run `verify-run`, loop to §0.1 (`-PrevSha`) + fresh Reviewer.

## 2. L / XL / XXL — hierarchical L0–L4 (`hierarchical.md`)

1. Run `b3-guard review-inventory` (L0; `PARTITION_INCOMPLETE` if unsafe) + `review-ledger init` (`-MaxConcurrency <=4`, monotonic `passes_used`/`pass_chain`, default `12` L/XL or `24` XXL >0); advise PR split if mergeable; never skip units.
2. **L1–L3:** L1 specialists ONLY if `l1_specialists != none` (else log `l1_skip_rationale`); L2 cohesive units (`L/XL<=4`; `XXL` dynamic `<=4` conc, max **3**/unit); L3 cross-unit (max **2**).
3. **L4 Gate:** require `review-ledger check` = `LEDGER_GATE_PASS`; moved `target_ref`, stale state/receipt, uncovered/oversized unit, rejected `CRITICAL` waiver, pass tamper, or exhausted budget -> `INCOMPLETE`/`BLOCKED`.

## 3. Stop & report

Compact report: `size_class` + `risk_level`, units/ledger, iter blocker counts, active/closed findings, verify cmds/receipts, skipped specialists rationale, `review_independence` (`SINGLE_AGENT_LIMIT` if unisolated), outcome (`PASS|FAIL|STUCK|INCOMPLETE|BLOCKED`).
