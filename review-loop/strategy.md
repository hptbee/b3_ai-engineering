# Orchestrator procedure

**Trigger:** `commands/b3-review-loop.md` or `/b3-ship` `Review`. Loop **Guard -> Review -> Fix -> Verify -> fresh Review** until gate, `STUCK`, or cap (never stop after pass 1).

**Orchestrator:** never review+fix in one pass; merge findings; **alone** emit `PASS`|`FAIL`|`STUCK`|`INCOMPLETE`|`BLOCKED`. Self-sufficient — load [`hierarchical.md`](hierarchical.md) only on `L`/`XL`/`XXL`; skip `spec.md`/`sizing.md`/`models.md` unless needed.

## Roles & dispatch (Risk-based, existing `b3-*` roles only)

- **Lean loads:** load [dispatch](../workflows/references/dispatch-naming.md) + optional `.b3/models.md`/`~/.b3/models.md` **once/loop**; load [context-routing](../workflows/references/context-routing.md) `<=1x/loop` **only when triggered** (optional MCPs active in host, cross-file symbol/impact beyond diff, or multi-iter `context-cache` reuse) — **skip** on direct-known / native-only / single-pass diffs (default `context_hint: tools=native cache=none`). Pass 1L `context_hint:` to Reviewer/Fixer (never paste `context-routing.md`); cache host IDs.
- **Reviewer (`b3-reviewer`+specialists):** fresh, read-only; `agents/b3-reviewer.md` self-contained (skip `code-review/SKILL.md`/`review-template.md`). Decouple `risk_level` from size (`XS` auth=`CRITICAL`; `XXL` docs=`LOW`; never LOC alone):
  - `LOW`: 0-tok checks + 1 fresh `b3-reviewer` (skip specialists).
  - `MEDIUM`: `b3-reviewer` + triggered specialist (`b3-{security,architecture,performance}-reviewer`).
  - `HIGH`: `b3-reviewer` + matching specialists + contract/dep review.
  - `CRITICAL`: deep review + mandatory specialists (self-waivers rejected) + cross-boundary `verify-run` receipt.
- **Fixer:** reuse `impl_agent` (`fixer_agent`) until Tier-1 breaker forces fresh `agents/b3-fixer.md` (`verification/SKILL.md` on demand); standalone -> dispatch fresh `b3-fixer` (`OPEN`+targets+`verify_cmd`). No subagents: hat-change + `review_independence: SINGLE_AGENT_LIMIT`.
- **State/replies:** standalone `.b3/ship/review-loop/<slug>/` (`state.md`,`ledger.md`,`logs/`,`evidence/verify.verify`); `review-ledger normalize` legacy tiers. Reviewer <=25L (`Verdict`+table+checked/skipped); Fixer <=20L (`id (bug_class)->files->verify_cmd`; 1L ok,<=35L/log red).

## 0. Target, Guard, Size × Risk & Status

1. Run `b3-guard.{ps1,sh} diff-scope` (`-BaseSha`, opt `-PrevSha`; never `HEAD~1`) + `mechanical-check` (`-BaseSha`,`-AllowedPaths`,`-Obsoletes`) + `symbol-check` on refactors. Initial empty diff->`INCOMPLETE`; `CLEAN_AFTER_FIX`->§1 on `delta_files`. Fix `exit 2` first.
2. **Sizing:** `NOISE_ONLY` (`files=0`+checks+gen provenance ok=`PASS`); smallest fitting BOTH (`XS` `<=3f,<=100L`; `S` `<=8f,<=300L`; `M` `<=20f,<=800L`)->**§1** (max 5); (`L` `<50f,<2000L`; `XL` `<=100f,<=5000L`; `XXL` dynamic units)->**§2** (`hierarchical.md`).
3. **Statuses (`R001`..):** `OPEN`=blocking `CONFIRMED` (`CRITICAL|HIGH|MEDIUM`,`CONFIRMED REDUNDANCY`,hot `EVIDENCED RISK`); `FIXED`=unverified (`VERIFIED`/`CLOSED`); `REJECTED`=`FALSE_POSITIVE` (+why); `ACCEPTED`=`INTENTIONAL COMPLEXITY`/OOS (+why); `SPECULATIVE`=unproven/`LOW`-conf/`LIKELY REDUNDANT` (non-blocking).

## 1. XS / S / M — full-PR loop (max 5 iterations)

1. **Reviewer:** fresh independent pass + 1L `context_hint:` — Iter 1 diff-first (direct-known short-circuit; skip graph scans and `context-routing.md` when native diff suffices; escalate to targeted symbol/impact only if needed; optional `b3-guard context-cache` on anchors); Iter 2+ delta-first (`delta_files`+callers+`OPEN`+changed contracts; reuse valid `context-cache` when recorded, invalidate on anchor/contract/summary/graph-SHA drift, no repo reload/graph repeat; never "did we fix R001?"; respect `closed:`). MCP failure -> native fallback, never false `PASS`.
2. **Gate:** `b3-guard verify-check` first — `OPEN`=0 + `VERIFY_VALID` on live tree + risk evidence -> `PASS` (`FAIL` on failed check; `UNKNOWN / INCOMPLETE` on missing/stale/corrupt receipt or tool error).
3. **Breaker:** (a) finding survives 2 rounds -> rewrite brief/fresh `b3-fixer`; (b) same bug class recurs 2 rounds -> back to `Scope`/design. Stop `STUCK`/`INCOMPLETE` on flat/rising blockers, oscillation, no-op, or cap (`FAIL` if `CONFIRMED` blockers remain).
4. **Fix+Verify:** before Fixer, `prev_sha` (`b3-guard snapshot`; fails closed on secrets/dirty submodules). Bug-class sweep `OPEN`, `verify-run`, loop §0.1 (`-PrevSha`) + fresh Reviewer.

## 2. L / XL / XXL — hierarchical L0–L4 (`hierarchical.md`)

1. `b3-guard review-inventory` (L0; `PARTITION_INCOMPLETE` if unsafe) + `review-ledger init` (`-MaxConcurrency <=4`, monotonic `passes_used`/`pass_chain`, def `12` L/XL,`24` XXL >0); advise split if mergeable; never skip units.
2. **L1–L3:** L1 only if `l1_specialists != none` (else `l1_skip_rationale`); L2 cohesive units (`L/XL<=4`; `XXL` dynamic `<=4` conc, max 3/unit); L3 cross-unit (max 2).
3. **L4 Gate:** `review-ledger check`=`LEDGER_GATE_PASS`; moved `target_ref`, stale state/receipt, uncovered/oversized unit, rejected `CRITICAL` waiver, pass tamper, or exhausted budget -> `INCOMPLETE`/`BLOCKED`.

## 3. Stop & report

Compact: `size_class`+`risk_level`, units/ledger, iter counts, active/closed findings, verify receipts, skipped-specialist rationale, `review_independence` (`SINGLE_AGENT_LIMIT` if unisolated), outcome (`PASS|FAIL|STUCK|INCOMPLETE|BLOCKED`).
