# Hierarchical Review (`L` / `XL` / `XXL`)

Load **only** when `size_class` is `L`, `XL`, or `XXL` (never on `always-on` or `XS`/`S`/`M` runs). Reuses only existing `b3-*` roles, `scripts/b3-guard.{ps1,sh}`, and the orchestrator's **conditional** on-demand [`../workflows/references/context-routing.md`](../workflows/references/context-routing.md) load — load `<=1x/loop` only when optional MCPs are active or multi-unit/L2 `context-cache` reuse applies, skipping it on native direct-known units (pass 1L `context_hint:` per unit, default `context_hint: tools=native cache=none`; never paste).

## Workflow & Budgets by Large Tier

| Tier | Partitioning | Unit cap | Concurrency | Budget rule |
| --- | --- | --- | --- | --- |
| `L` (`<50f, <2000L`) | Bounded cohesive units (coalesced `<= 4` units) | 3 iter/unit | Up to 4 | Default monotonic `max_passes=12`; recommend split if multi-feature |
| `XL` (`<=100f, <=5000L`) | Bounded cohesive units (coalesced `<= 4` units) | 3 iter/unit | Up to 4 | Default monotonic `max_passes=12`; deeper contract + cross-unit review |
| `XXL` (`>100f or >5000L`, 5k–30k+ LOC) | **Dynamic** cohesive units (`>5000L` buckets subdivided by dir/contracts/feature/imports; fail `PARTITION_INCOMPLETE` if impossible) | 3 iter/unit | Up to 4 (`--max-concurrency 1..4`) | Default monotonic `max_passes=24` (positive `--max-passes N` override; stop `INCOMPLETE` on exhaustion, never skip units) |

## Five Hierarchical Levels (`XXL` & Multi-Unit `L`/`XL`)

### Level 0 — Deterministic Inventory (`0 LLM tokens`)
Run `scripts/b3-guard.{ps1,sh} review-inventory` (`-BaseSha`, optional `-TargetRef`, `-MaxConcurrency`):
- Collects T-shirt `size_class`, files/LOC, `change_types`, `contract_files`, `generated_files`, `test_files`, `noise_files`, decoupled PR & per-unit `risk_level` / `risk_signals` / `recommended_specialists`, conditional Level-1 dispatch (`l1_specialists`, `l1_skip_rationale`), `split_recommended`, and bounded cohesive `unit|U01|...` slices (`L`/`XL` coalesced `<= 4`; oversized buckets subdivided without arbitrary LOC slicing; paired tests preserved). Fails `PARTITION_INCOMPLETE` (`exit 2`) if safe bounded partitioning is impossible.
- Initialize resumable tamper-evident coverage ledger immediately:
  `scripts/b3-guard.{ps1,sh} review-ledger -Action init -LedgerPath .b3/ship/review-loop/<slug>/ledger.md [-MaxConcurrency N] [-MaxPasses M] [-ReviewIndependence UNKNOWN|INDEPENDENT|SINGLE_AGENT_LIMIT]`
  (Defaults to `UNKNOWN` — never assumes `INDEPENDENT`; fails closed before creating objects on sensitive untracked files, dirty submodules, or unsafe partitions.)
- If `split_recommended=true` and units are independently mergeable, advise splitting into stacked/feature PRs; if reviewed here, execute Levels 1–4 across **all** units.

### Level 1 — Conditional Architecture & Shared Contract Review
Dispatch Level 1 **only when `l1_specialists != none`** (`contract_files` non-empty or PR `risk_signals` justify `b3-architecture-reviewer`, `b3-security-reviewer`, or `b3-performance-reviewer`):
- When `l1_specialists=none` (e.g., verified `LOW`-risk docs-only or isolated changes with zero contract/arch signals), **skip Level 1 specialist calls** and record `l1_skip_rationale` (`low-risk-docs-only` / `low-risk-isolated-no-contracts` / `no-contract-or-arch-signals`).
- When dispatched, run the listed read-only `l1_specialists` over `contract_files`, schema/migration boundaries, data/state flow, transaction/concurrency invariants, and dependency blast radius only (never full unit bodies), and record contract invariants for Level 2 briefs.

### Level 2 — Bounded Parallel Unit Review (Up to 4 Concurrent)
Process active `PENDING`/`IN_PROGRESS`/`STALE` units in batches of `<= max_concurrency` (`4` default, lower via `-MaxConcurrency` if rate/context constrained):
1. **Isolated context packet:** pass ONLY unit `files_csv` + relevant `contract_files` + Level 1 invariants (if any) + 1L `context_hint:` + unit `risk`/`specialists` + unit active findings (`<= 25L` Reviewer, `<= 20L` Fixer caps; never broadcast full PR). Optionally record immutable unit anchors via `b3-guard context-cache`: bind `contract_files` (and `read_only_deps`) via `anchor_paths` and bind recorded Level 1 invariants via `summary_ref` (SHA-256 verified under `.b3/ship/`).
2. **Risk-based specialist dispatch per unit:**
   - `LOW`: 1 fresh `b3-reviewer` only (skip specialists; record `rationale=low-risk-doc-or-local`).
   - `MEDIUM`: fresh `b3-reviewer`; add triggered specialist if justified (or `>=5`-char skip rationale).
   - `HIGH`: fresh `b3-reviewer` + `recommended_specialists` (or non-waiver `>=15`-char, `>=2` distinct 3+-letter word rationale) + scoped `verify-run` receipt covering `files_csv` on code units.
   - `CRITICAL`: fresh `b3-reviewer` + mandatory `recommended_specialists` + scoped `verify-run` receipt on code units (fail closed; free-form rationale rejected and self-declared `WAIVER:...` attempts rejected with `LEDGER_BLOCKED` until a trusted owner approval mechanism exists).
3. **Bounded unit loop:** `Review -> Fix -> Verify (verify-run) -> fresh Re-review` (max 3 iter/unit, `diff-scope -PrevSha` deltas Iter 2+; reuse valid unit `context-cache`, invalidate on anchor/contract/summary/graph-SHA drift, skip full repo reload or repeat graph scans; MCP failure -> native fallback without false `PASS`; reuse `fixer_agent` per unit until Tier-1 breaker).
4. **Update ledger after each unit:** `review-ledger -Action update -LedgerPath ... -UnitId U0N -Status REVIEWED|BLOCKED|INCOMPLETE -Specialists ... -Findings ... -ReceiptPath ...`.
   - `passes_used` advances monotonically (`pass_chain` mandatory + append-only `## Pass Log`); resetting/tampering `passes_used`, stripping `pass_chain`, raising `max_passes`, or upgrading `SINGLE_AGENT_LIMIT->INDEPENDENT` fails closed (`LEDGER_FAIL`/`LEDGER_CORRUPT`).
   - Never rely solely on file-extension exemptions for **generated code** (`*.generated.*`, `*.pb.*`, `*.Designer.cs`, `*.g.cs`): inspect generator inputs/provenance and record verification/rationale in unit notes.

### Level 3 — Cross-Unit Integration Review
After units complete (`0` blocking `OPEN`), dispatch fresh `b3-reviewer` (+ `b3-architecture-reviewer` / `b3-security-reviewer` / `b3-performance-reviewer` only if cross-unit signals trigger) with 1L `context_hint:` on `contract_files`, interfaces, error propagation, transactions, security boundaries, dependency changes, and cross-unit duplication (reuse valid `context-cache` across L3 re-reviews; skip full repo reload/graph repeats; native fallback on MCP failure). **Do not blindly re-read untouched unit internals.** Max **2** iter. Record `-Action update -CrossUnitStatus REVIEWED`.

### Level 4 — Final Fail-Closed Quality Gate
Run `scripts/b3-guard.{ps1,sh} review-ledger -Action check -LedgerPath ...` (plus `mechanical-check` / `symbol-check` if edits occurred):
- Verifies complete live coverage, bounded units (`L`/`XL <= 4`; no oversized unit), no `size_class` escalation (`LEDGER_STALE`), unchanged `target_ref`->`target_sha`, all units `REVIEWED` with `0` `OPEN`/unverified `FIXED`, fresh `unit_tree_hash`+`cross_unit_tree_hash`, live `risk_level` + specialist compliance (`CRITICAL` waivers rejected; `SINGLE_AGENT_LIMIT` blocked on `HIGH`/`CRITICAL`), `target_sha`-bound `verify_receipt` (`HIGH`/`CRITICAL` code units), mandatory `pass_chain` + immutable `max_passes` (`XS/S/M: 5`, `L/XL: 12`, `XXL: 24`).
- **Resume after interruption:** read `ledger.md`, run `review-ledger normalize` if legacy `SMALL|MEDIUM|LARGE|VERY_LARGE` sizes appear, run `review-ledger check` to identify `PENDING`/`INCOMPLETE`/`STALE` units invalidated by changed files, shared contracts, or risk changes, and re-run only invalidated/unreviewed units plus Level 3 when needed.
- Budget exhaustion, missing receipt/tool failure, stale unit, or incomplete ledger -> **`INCOMPLETE` or `BLOCKED`** (never `PASS` from silence).
