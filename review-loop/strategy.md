# Orchestrator procedure

**Trigger:** `commands/b3-review-loop.md` or `/b3-ship` `Review`. Loop **Guard -> Review -> Fix -> Verify -> fresh Review** until gate, `STUCK`, or cap (never stop Pass 1).

**Orchestrator:** never review+fix in 1 pass; merge findings; **alone** emit `PASS`|`FAIL`|`STUCK`|`INCOMPLETE`|`BLOCKED`. Self-sufficient — load [`hierarchical.md`](hierarchical.md) only on `L`/`XL`/`XXL`; skip `spec.md`/`sizing.md`/`models.md` unless needed.

## Roles & dispatch (Risk-based, existing `b3-*` roles only)

- **Lean loads:** load [dispatch](../workflows/references/dispatch-naming.md) + optional `.b3/models.md`/`~/.b3/models.md` **once/loop**; load [context-routing](../workflows/references/context-routing.md) `<=1x/loop` **only when triggered** (MCPs, cross-file impact, or `context-cache`), **skip** on direct-known/native-only/1-pass diffs (`context_hint: tools=native cache=none`). Pass 1L `context_hint:` only; cache host IDs.
- **Reviewer (`b3-reviewer`+specialists):** fresh, read-only; `agents/b3-reviewer.md` self-contained (skip `code-review/SKILL.md`/`review-template.md`). `risk_level` != size (`XS` auth=`CRITICAL`; `XXL` docs=`LOW`):
  - `LOW`: 0-tok checks + 1 fresh `b3-reviewer` (skip specialists).
  - `MEDIUM`: `b3-reviewer` + triggered specialist (`b3-{security,architecture,performance}-reviewer`).
  - `HIGH`: `b3-reviewer` + specialists + contract/dep review.
  - `CRITICAL`: deep review + mandatory specialists (no self-waiver) + cross-boundary `verify-run` receipt.
- **Fixer:** reuse `impl_agent` until Tier-1 breaker forces fresh `agents/b3-fixer.md` (`verification/SKILL.md` on demand); standalone -> dispatch fresh `b3-fixer` (`OPEN`+targets+`verify_cmd`). No subagents: hat-change + `review_independence: SINGLE_AGENT_LIMIT` (cannot emit `PASS`/`VERIFIED`/`MERGE_AUTHORIZED` on `HIGH`/`CRITICAL` -> `INCOMPLETE`, needs independent/human review; blocks `auto_merge`).
- **State/replies:** standalone `.b3/ship/review-loop/<slug>/` (`state.md`,`ledger.md`,`logs/`,`evidence/verify.verify`); `review-ledger normalize`. Reviewer <=25L (`Verdict`+table+checked/skipped); Fixer <=20L (`id (bug_class)->files->verify_cmd`; 1L ok,<=35L/log red).

## 0. Target, Guard, Size × Risk & Status

1. Run `b3-guard.{ps1,sh} diff-scope` (`-BaseSha`, opt `-PrevSha`; never `HEAD~1`) + `mechanical-check` (`-BaseSha`,`-AllowedPaths`,`-Obsoletes`) + `symbol-check` on refactors. Empty diff->`INCOMPLETE`; `CLEAN_AFTER_FIX`->§1 on `delta_files`. Fix `exit 2` first.
2. **Sizing:** `NOISE_ONLY` (`files=0`+checks+gen provenance ok=`PASS`); smallest fitting BOTH (`XS` `<=3f,<=100L`; `S` `<=8f,<=300L`; `M` `<=20f,<=800L`)->**§1** (max 5); (`L` `<50f,<2000L`; `XL` `<=100f,<=5000L`; `XXL` dynamic)->**§2** (`hierarchical.md`).
3. **Statuses (`R001`..):** `OPEN`=blocking `CONFIRMED` (`CRITICAL|HIGH|MEDIUM`,`CONFIRMED REDUNDANCY`,hot `EVIDENCED RISK`); `FIXED`=unverified (`VERIFIED`/`CLOSED`); `REJECTED`=`FALSE_POSITIVE` (+why); `ACCEPTED`=`INTENTIONAL COMPLEXITY`/OOS (+why); `SPECULATIVE`=unproven/`LOW`-conf/`LIKELY REDUNDANT` (non-blocking).

## 1. XS / S / M — full-PR loop (max 5 iterations)

1. **Reviewer:** fresh pass + 1L `context_hint:` (`context-routing.md` if triggered) — Iter 1 diff-first; Iter 2+ delta-first (`delta_files`+callers+`OPEN`+contracts; never "did we fix R001?"; respect `closed:`). MCP error -> native fallback, never false `PASS`.
2. **Gate:** `b3-guard verify-check` first — `OPEN`=0 + `VERIFY_VALID` on live tree + risk evidence -> `PASS` (`FAIL` on failed check; `UNKNOWN / INCOMPLETE` on missing/stale/corrupt receipt, tool error, or `SINGLE_AGENT_LIMIT` on `HIGH`/`CRITICAL`).
3. **Breaker:** (a) finding survives 2 rounds -> rewrite brief/fresh `b3-fixer`; (b) same bug class recurs 2 rounds -> back to `Scope`/design. Stop `STUCK`/`INCOMPLETE` on flat/rising blockers, oscillation, no-op, or cap (`FAIL` if `CONFIRMED` blockers remain).
4. **Fix+Verify:** snapshot `prev_sha` (`b3-guard snapshot`; fails closed on secrets/dirty submodules), sweep `OPEN` by bug class, `verify-run`, loop §0.1 (`-PrevSha`) + fresh Reviewer.

## 2. L / XL / XXL — hierarchical L0–L4 (`hierarchical.md`)

1. `b3-guard review-inventory` (L0; `PARTITION_INCOMPLETE` if unsafe) + `review-ledger init` (`-MaxConcurrency <=4`, monotonic `passes_used`/`pass_chain`, def `12` L/XL,`24` XXL >0); advise split if mergeable; never skip units.
2. **L1–L3:** L1 if `l1_specialists != none` (else `l1_skip_rationale`); L2 disjoint units concurrently (`MaxConcurrency<=4`, single-writer `review-ledger`, sequential fallback if host unparallel; `L/XL<=4`; `XXL` dynamic, max 3/unit); L3 cross-unit (max 2) + `verify-run` mandatory after parallel impl waves.
3. **L4 Gate:** `review-ledger check`=`LEDGER_GATE_PASS`; moved `target_ref`, stale receipt, uncovered/oversized unit, rejected `CRITICAL` waiver, pass tamper, or cap -> `INCOMPLETE`/`BLOCKED`.

## 3. Stop & report

Compact: `size_class`+`risk_level`, units/ledger, iters, active/closed findings, receipts, skipped-specialist rationale, `review_independence` (`SINGLE_AGENT_LIMIT` caps `HIGH`/`CRITICAL` to `INCOMPLETE`, blocks `auto_merge`), outcome (`PASS|FAIL|STUCK|INCOMPLETE|BLOCKED`).
