# Orchestrator procedure

**Trigger:** `commands/b3-review-loop.md` or `/b3-ship` `Review`. Loop **Guard -> Review -> Fix -> Verify -> fresh Review** until gate, `STUCK`, or cap (never stop Pass 1).

**Orchestrator:** never review+fix in 1 pass; merge findings; **alone** emit `PASS`|`FAIL`|`STUCK`|`INCOMPLETE`|`BLOCKED`. Load [`hierarchical.md`](hierarchical.md) only on `L`/`XL`/`XXL`; skip `spec.md`/`sizing.md`/`models.md` unless needed.

## Roles & dispatch (`b3-*` roles only)

- **Lean loads:** [dispatch](../workflows/references/dispatch-naming.md) + `.b3/models.md` **1x/loop**; [context-routing](../workflows/references/context-routing.md) `<=1x/loop` **only when triggered** (MCPs/cross-file/`context-cache`), **skip** on direct-known/native-only/1-pass (`context_hint: tools=native cache=none`). Pass 1L `context_hint:`; cache IDs; no nested subagents.
- **Reviewer (`b3-reviewer` + specialists):** fresh, read-only; `agents/b3-reviewer.md` self-contained (skip `code-review/SKILL.md`/`review-template.md`). Fan out `b3-reviewer` + triggered specialists concurrently in `SHARED_READ_ONLY` (`dispatch-naming.md`); `risk_level` != size:
  - `LOW`: 0-tok checks + 1 fresh `b3-reviewer`.
  - `MEDIUM`: `b3-reviewer` + triggered specialist (`b3-{security,architecture,performance}-reviewer`).
  - `HIGH`: `b3-reviewer` + specialists + contract/dep review.
  - `CRITICAL`: deep review + mandatory specialists (no waiver) + cross-boundary `b3 guard verify-run`.
- **Fixer:** reuse `impl_agent` until Tier-1 -> `agents/b3-fixer.md` (`verification/SKILL.md` on demand); standalone -> `b3-fixer` (`OPEN`+targets+`verify_cmd`). Disjoint confirmed fixes may run concurrently via `b3 guard check-wave --partition` + `mechanical-check` (`dispatch-naming.md`), followed by targeted re-verification. No subagents: hat-change -> `review_independence: SINGLE_AGENT_LIMIT` (§1.2).
- **State/replies:** standalone `.b3/ship/review-loop/<slug>/` (`state.md`,`ledger.md`,`logs/`,`verify.verify`; `b3 guard review-ledger --action normalize`). Reviewer `<=25L` (`Verdict`+table+checks); Fixer `<=20L` (`id->files->cmd`; 1L ok, `<=35L`/log red).

## 0. Target, Guard, Size × Risk & Status

1. Run `b3 guard diff-scope` (`--base-sha`, opt `--prev-sha`; never `HEAD~1`) + `mechanical-check` (`--base-sha`, `--allowed-paths`, `--protected-paths`, `--obsoletes`) + `symbol-check` (refactors). Empty diff->`INCOMPLETE`; `CLEAN_AFTER_FIX`->§1 on `delta_files`. Fix `exit 2` first.
2. **Sizing:** `NOISE_ONLY` (`files=0`+checks ok=`PASS`); smallest fitting BOTH (`XS` `<=3f,<=100L`; `S` `<=8f,<=300L`; `M` `<=20f,<=800L`)->**§1** (max 5); (`L` `<50f,<2000L`; `XL` `<=100f,<=5000L`; `XXL` dynamic)->**§2** (`hierarchical.md`).
3. **Statuses (`R001`..):** `OPEN`=blocking `CONFIRMED` (`CRITICAL|HIGH|MEDIUM`,`CONFIRMED REDUNDANCY`,hot `EVIDENCED RISK`); `FIXED`=unverified (`VERIFIED`/`CLOSED`); `REJECTED`=`FALSE_POSITIVE` (+why); `ACCEPTED`=`INTENTIONAL COMPLEXITY`/OOS (+why); `SPECULATIVE`=unproven/`LOW`-conf/`LIKELY REDUNDANT` (non-blocking).

## 1. XS / S / M — full-PR loop (max 5 iterations)

1. **Reviewer:** fresh pass + 1L `context_hint:` — Iter 1 diff-first; Iter 2+ delta-first (`delta_files`+callers+`OPEN`+contracts; never "did we fix R001?"; respect `closed:`). MCP error -> native fallback, never false `PASS`.
2. **Gate:** `b3 guard verify-check` first — `OPEN`=0 + `VERIFY_VALID` + risk evidence -> `PASS` (`FAIL` on failed check; `UNKNOWN / INCOMPLETE` on bad/stale receipt, tool error, or `SINGLE_AGENT_LIMIT` on `HIGH`/`CRITICAL`, which cannot emit `PASS` on `HIGH`/`CRITICAL` -> `INCOMPLETE` and blocks `auto_merge`).
3. **Breaker:** (a) finding survives 2 rounds -> rewrite brief/fresh `b3-fixer`; (b) bug class recurs 2 rounds -> `Scope`/design. Stop `STUCK`/`INCOMPLETE` on flat/rising blockers, loops, no-op, or cap (`FAIL` if `CONFIRMED` blockers remain).
4. **Fix+Verify:** `b3 guard snapshot` `prev_sha`, sweep `OPEN` by bug class (concurrent only when disjoint via `check-wave --partition`), `verify-run`, loop §0.1 (`--prev-sha`) + fresh Reviewer.

## 2. L / XL / XXL — hierarchical L0–L4 (`hierarchical.md`)

1. `b3 guard review-inventory` (L0; `PARTITION_INCOMPLETE` if unsafe) + `b3 guard review-ledger --action init` (adaptive `--max-concurrency`, `passes_used`/`pass_chain`, def `12` L/XL,`24` XXL); advise split if separable; never skip units.
2. **L1–L3:** L1 if `l1_specialists != none` (else `l1_skip_rationale`); L2 `SHARED_READ_ONLY` concurrent units (adaptive concurrency per `dispatch-naming.md`, single-writer `review-ledger`, max 3/unit); post-integration L3 cross-unit (max 2) + `verify-run` mandatory after parallel code waves.
3. **L4 Gate:** `b3 guard review-ledger --action check`=`LEDGER_GATE_PASS`; moved `target_ref`, stale receipt, uncovered/oversized unit, bad `CRITICAL` waiver, pass tamper, or cap -> `INCOMPLETE`/`BLOCKED`.

## 3. Stop & report

Report `size_class`+`risk_level`, units/ledger, iters, findings, receipts, skipped-specialist rationale, `review_independence`, outcome (`PASS|FAIL|STUCK|INCOMPLETE|BLOCKED`). PR post: verified result only (`pr-feedback/SKILL.md`).
