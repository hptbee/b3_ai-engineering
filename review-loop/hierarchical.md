# Hierarchical Review (`L` / `XL` / `XXL`)

Load **only** when `size_class` is `L`, `XL`, or `XXL` (never on `always-on` or `XS`/`S`/`M` runs). Reuses `b3-*` roles, `b3 guard`, and `strategy.md`'s conditional `context-routing.md` rules (pass 1L `context_hint:` per unit, default `context_hint: tools=native cache=none`; never paste).

## Resolved Config, Defaults & Safety Ceilings

- **Resolved config (authoritative):** AI Orchestrator MUST consume the `size_class`, units, and limits emitted by `b3 guard review-inventory` / `b3 guard review-ledger` (resolved from `config.toml` `[review]`, `[review.sizing]`, `[parallel]`) instead of recomputing T-shirt thresholds manually.
- **Built-in defaults (when unset):** `L` (`<50f, <2000L`), `XL` (`<=100f, <=5000L`), `XXL` (`>100f or >5000L`); `review.max_files_per_unit=100`, `review.max_loc_per_unit=5000`; `max_passes` (`XS/S/M`: `review.max_iterations` def `5`, `L/XL`: `12`, `XXL`: `24`).
- **Mandatory safety ceilings (non-overridable):** `L`/`XL` coalesced `<= 4` units, `3` iter/unit, `PARTITION_INCOMPLETE` fail-closed, monotonic `passes_used` / immutable `max_passes`, `CRITICAL` no-waiver, `SINGLE_AGENT_LIMIT` blocked on `HIGH`/`CRITICAL`.

| Tier | Partitioning | Unit cap | Concurrency | Budget rule |
| --- | --- | --- | --- | --- |
| `L` | Bounded cohesive units (coalesced `<= 4` units) | 3 iter/unit | Adaptive (`dispatch-naming.md`) | Monotonic `max_passes` (`12` def); recommend split if multi-feature |
| `XL` | Bounded cohesive units (coalesced `<= 4` units) | 3 iter/unit | Adaptive (`dispatch-naming.md`) | Monotonic `max_passes` (`12` def); deeper contract + cross-unit review |
| `XXL` | **Dynamic** cohesive units (oversized buckets subdivided by dir/contracts/feature/imports; fail `PARTITION_INCOMPLETE` if impossible) | 3 iter/unit | Adaptive (`parallel.max_concurrency` `1..64`) | Monotonic `max_passes` (`24` def or `--max-passes N`; stop `INCOMPLETE` on exhaustion, never skip units) |

## Five Hierarchical Levels (`XXL` & Multi-Unit `L`/`XL`)

### Level 0 — Deterministic Inventory (`0 LLM tokens`)
Run `b3 guard review-inventory` (`--base-sha`, optional `--target-ref`, `--max-concurrency`); once L0 runs `review-inventory`, do not re-run full `diff-scope`:
- Collects T-shirt `size_class`, files/LOC, `change_types`, `contract_files`, `generated_files`, `test_files`, `noise_files`, decoupled PR & per-unit `risk_level` / `risk_signals` / `recommended_specialists`, conditional Level-1 dispatch (`l1_specialists`, `l1_skip_rationale`), `split_recommended`, and cohesive `unit|U01|...` slices (`L`/`XL` coalesced `<= 4`; oversized buckets subdivided without arbitrary LOC slicing; paired tests preserved). Fails `PARTITION_INCOMPLETE` (`exit 2`) if safe partitioning is impossible.
- Initialize resumable tamper-evident coverage ledger immediately:
  `b3 guard review-ledger --action init --ledger-path .b3/ship/review-loop/<slug>/ledger.md [--max-concurrency N] [--max-passes M] [--review-independence UNKNOWN|INDEPENDENT|SINGLE_AGENT_LIMIT]`
  (Defaults to `UNKNOWN` — never assumes `INDEPENDENT`; fails closed before creating objects on sensitive untracked files, dirty submodules, or unsafe partitions.)
- If `split_recommended=true` and units are independently mergeable, advise splitting into stacked/feature PRs; if reviewed here, execute Levels 1–4 across **all** units.

### Level 1 — Conditional Architecture & Shared Contract Review
Dispatch Level 1 **only when `l1_specialists != none`** (`contract_files` non-empty or PR `risk_signals` justify `b3-architecture-reviewer`, `b3-security-reviewer`, or `b3-performance-reviewer`):
- When `l1_specialists=none` (e.g., verified `LOW`-risk docs-only or isolated changes with zero contract/arch signals), **skip Level 1 specialist calls** and record `l1_skip_rationale` (`low-risk-docs-only` / `low-risk-isolated-no-contracts` / `no-contract-or-arch-signals`).
- When dispatched, run the listed `SHARED_READ_ONLY` `l1_specialists` concurrently over `contract_files`, schema/migration boundaries, data/state flow, transaction/concurrency invariants, and dependency blast radius only (never full unit bodies), and record contract invariants for Level 2 briefs.

### Level 2 — Adaptive Concurrent Unit Review
Process active `PENDING`/`IN_PROGRESS`/`STALE` units concurrently per `dispatch-naming.md` (scaling up to host/rate/context budget via `--max-concurrency` without fixed `4` caps):
1. **Isolated context packet:** pass ONLY unit `files_csv` + relevant `contract_files` + Level 1 invariants (if any) + 1L `context_hint:` + unit `risk`/`specialists` + unit active findings (`<= 25L` Reviewer, `<= 20L` Fixer caps; never broadcast full PR). Optionally record immutable unit anchors via `b3 guard context-cache`: bind `contract_files` (`read_only_deps`) via `--anchor-paths` and recorded Level 1 invariants via SHA-256 `--summary-ref` (verified under `.b3/ship/`).
2. **Risk-based specialist dispatch per unit (concurrent `SHARED_READ_ONLY` when triggered):**
   - `LOW`: 1 fresh `b3-reviewer` only (skip specialists; record `rationale=low-risk-doc-or-local`).
   - `MEDIUM`: fresh `b3-reviewer`; add triggered specialist if justified (or explicit non-empty/non-`none`/non-`WAIVER:` skip rationale).
   - `HIGH`: fresh `b3-reviewer` + `recommended_specialists` (or explicit non-waiver skip rationale) + scoped `verify-run` receipt covering `files_csv` on code units.
   - `CRITICAL`: fresh `b3-reviewer` + mandatory `recommended_specialists` + scoped `verify-run` receipt on code units (fail closed; free-form rationale and self-declared `WAIVER:...` attempts rejected with `LEDGER_BLOCKED`).
3. **Bounded unit loop:** `Review -> Fix -> Verify (b3 guard verify-run) -> fresh Re-review` (max 3 iter/unit, `b3 guard diff-scope --prev-sha` deltas Iter 2+; reuse valid unit `context-cache`, invalidate on anchor/contract/summary/graph-SHA drift; non-overlapping unit fixes may run concurrently via `check-wave --partition` + targeted re-verification; reuse `fixer_agent` per unit until Tier-1 breaker).
4. **Update ledger after each unit (single-writer):** `b3 guard review-ledger --action update --ledger-path ... --unit-id U0N --status REVIEWED|BLOCKED|INCOMPLETE --specialists ... --findings ... --receipt-path ...`.
   - `passes_used` advances monotonically; budget/header tampering fails closed (`LEDGER_FAIL`/`LEDGER_CORRUPT`).
   - Never rely solely on file-extension exemptions for **generated code** (`*.generated.*`, `*.pb.*`, `*.Designer.cs`, `*.g.cs`): inspect generator inputs/provenance and record verification/rationale in unit notes.

### Level 3 — Cross-Unit Integration Review
After units complete (`0` blocking `OPEN`), dispatch fresh `b3-reviewer` (+ triggered `b3-{architecture,security,performance}-reviewer` concurrently in `SHARED_READ_ONLY`) with 1L `context_hint:` on `contract_files`, interfaces, error propagation, transactions, security boundaries, dependency changes, and cross-unit duplication (reuse valid `context-cache` across L3 re-reviews). **Do not blindly re-read untouched unit internals.** Max **2** iter. Record `--action update --cross-unit-status REVIEWED`.

### Level 4 — Final Fail-Closed Quality Gate
Run `b3 guard review-ledger --action check --ledger-path ...` (re-run `mechanical-check` / `symbol-check` **only** if edits occurred since the last guard check; never re-run full `diff-scope` after L0 `review-inventory`). Confirmed `exit 2` (`MECHANICAL_FINDINGS`/`SYMBOL_FINDINGS` `dangling_refs`; `safety_hits` -> `BLOCKED`; proven textual false-positive `dangling_refs` documented) blocks/requires fix; advisory `exit 0` (`MECHANICAL_ADVISORY` `advisory_hits=` / `SYMBOL_ADVISORY` `orphan_internal`-only) surfaces to Reviewer for contextual triage alongside native compiler/linter/typechecker output without mechanically blocking commit:
- Verifies complete live coverage, bounded units (`L`/`XL <= 4`; no oversized unit), no `size_class` escalation (`LEDGER_STALE`), unchanged `target_ref`->`target_sha`, all units `REVIEWED` with `0` `OPEN`/unverified `FIXED`, fresh `unit_tree_hash`+`cross_unit_tree_hash`, live `risk_level` + specialist compliance (`CRITICAL` waivers rejected; `SINGLE_AGENT_LIMIT` blocked on `HIGH`/`CRITICAL`), `target_sha`-bound `verify_receipt` (`HIGH`/`CRITICAL` code units), monotonic `passes_used` + immutable `max_passes` (`XS/S/M: 5`, `L/XL: 12`, `XXL: 24`).
- **Resume after interruption:** read `ledger.md`, run `b3 guard review-ledger --action normalize` if legacy `SMALL|MEDIUM|LARGE|VERY_LARGE` sizes appear, run `--action check` to identify `PENDING`/`INCOMPLETE`/`STALE` units invalidated by changed files, shared contracts, or risk changes, and re-run only invalidated/unreviewed units plus Level 3 when needed.
- Budget exhaustion, missing receipt/tool failure, stale unit, or incomplete ledger -> **`INCOMPLETE` or `BLOCKED`** (never `PASS` from silence).
