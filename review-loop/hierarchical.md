# Hierarchical Review (`L` / `XL` / `XXL`)

Load **only** when `size_class` is `L`, `XL`, or `XXL` (never on `always-on` or `XS`/`S`/`M` runs). Reuses only existing `b3-*` roles and `scripts/b3-guard.{ps1,sh}`.

## Workflow & Budgets by Large Tier

| Tier | Partitioning | Unit cap | Concurrency | Budget rule |
| --- | --- | --- | --- | --- |
| `L` (`<50f, <2000L`) | Cohesive logical units when multi-module (<= 4) | 3 iter/unit | Up to 4 | Total reviewer passes <= 12; recommend split if multi-feature |
| `XL` (`<=100f, <=5000L`) | Cohesive logical units (<= 4) | 3 iter/unit | Up to 4 | Total reviewer passes <= 12; deeper contract + cross-unit review |
| `XXL` (`>100f or >5000L`, 5k–30k+ LOC) | **Dynamic** cohesive module+test units (no fixed total-unit cap) | 3 iter/unit | Up to 4 (`--max-concurrency 1..4`) | Default `max_passes=24` (explicit positive `--max-passes N` override; stop `INCOMPLETE` on exhaustion, never skip units) |

## Five Hierarchical Levels (`XXL` & Multi-Unit `L`/`XL`)

### Level 0 — Deterministic Inventory (`0 LLM tokens`)
Run `scripts/b3-guard.{ps1,sh} review-inventory` (`-BaseSha`, optional `-TargetRef`, `-MaxConcurrency`):
- Collects T-shirt `size_class`, files/LOC, `change_types`, `contract_files`, `generated_files`, `test_files`, `noise_files`, decoupled PR & per-unit `risk_level` / `risk_signals` / `recommended_specialists`, `split_recommended`, and cohesive `unit|U01|...` slices (paired tests stay with their code unit; never split by arbitrary LOC).
- Initialize resumable coverage ledger immediately:
  `scripts/b3-guard.{ps1,sh} review-ledger -Action init -LedgerPath .b3/ship/review-loop/<slug>/ledger.md [-MaxConcurrency N] [-MaxPasses M]`
  (Fails closed before creating objects on sensitive untracked files or dirty submodules.)
- If `split_recommended=true` and units are independently mergeable, advise splitting into stacked/feature PRs; if reviewed here, execute Levels 1–4 across **all** units.

### Level 1 — Architecture & Shared Contract Review
Before dispatching unit workers, run 1 read-only `agents/b3-architecture-reviewer.md` pass (plus `b3-security-reviewer.md` if PR `risk_signals` include `auth_security`/`fs_git_security`/destructive `db_migration_tx`) over `contract_files`, schema/migration boundaries, data/state flow, transaction/concurrency invariants, and dependency blast radius only (never full unit bodies). Record contract invariants passed into Level 2 briefs.

### Level 2 — Bounded Parallel Unit Review (Up to 4 Concurrent)
Process active `PENDING`/`IN_PROGRESS`/`STALE` units in batches of `<= max_concurrency` (`4` default, lower via `-MaxConcurrency` if rate/context constrained):
1. **Isolated context packet:** pass ONLY unit `files_csv` + relevant `contract_files` + Level 1 invariants + unit `risk`/`specialists` + unit active findings (`<= 25L` Reviewer, `<= 20L` Fixer caps; never broadcast full PR).
2. **Risk-based specialist dispatch per unit:**
   - `LOW`: 1 fresh `b3-reviewer` only (skip specialists; record `rationale=low-risk-doc-or-local`).
   - `MEDIUM`: fresh `b3-reviewer`; add triggered specialist only if domain signal justifies.
   - `HIGH`: fresh `b3-reviewer` + `recommended_specialists` (or explicit `>=5`-char skip rationale) + scoped `verify-run` receipt covering `files_csv` on code units.
   - `CRITICAL`: fresh `b3-reviewer` + mandatory `recommended_specialists` + scoped `verify-run` receipt on code units (fail closed; free-form rationale rejected — exception allowed only via auditable `WAIVER:approved_by=<id>;ticket=<ref>;reason=<10+ chars>` surfaced in `LEDGER_GATE_PASS`).
3. **Bounded unit loop:** `Review -> Fix -> Verify (verify-run) -> fresh Re-review` (max 3 iter/unit, `diff-scope -PrevSha` deltas Iter 2+; reuse `fixer_agent` per unit until Tier-1 breaker).
4. **Update ledger after each unit:** `review-ledger -Action update -LedgerPath ... -UnitId U0N -Status REVIEWED|BLOCKED|INCOMPLETE -Specialists ... -Findings ... -ReceiptPath ... [-PassesUsed N]`.
   - Never rely solely on file-extension exemptions for **generated code** (`*.generated.*`, `*.pb.*`, `*.Designer.cs`, `*.g.cs`): inspect generator inputs/provenance and record verification/rationale in unit notes.

### Level 3 — Cross-Unit Integration Review
After units complete (`0` blocking `OPEN`), dispatch fresh `b3-reviewer` (+ `b3-architecture-reviewer` / `b3-security-reviewer` / `b3-performance-reviewer` only if cross-unit signals trigger) on `contract_files`, interfaces, error propagation, transactions, security boundaries, dependency changes, and cross-unit duplication. **Do not blindly re-read untouched unit internals.** Max **2** iter. Record `-Action update -CrossUnitStatus REVIEWED`.

### Level 4 — Final Fail-Closed Quality Gate
Run `scripts/b3-guard.{ps1,sh} review-ledger -Action check -LedgerPath ...` (plus `mechanical-check` / `symbol-check` if edits occurred):
- Verifies complete live file coverage (no uncovered `review_files`), unchanged `target_ref` -> `target_sha` (branch movement or missing ref -> `LEDGER_STALE`), every unit `REVIEWED` with `0` `OPEN`/unverified `FIXED` findings, fresh `unit_tree_hash` (including `contract_files`) and fresh `cross_unit_tree_hash`, matching live `risk_level` + mandatory `CRITICAL` specialist/waiver compliance, valid non-stale `verify_receipt` (mandatory for `HIGH`/`CRITICAL` code units), and bounded `max_passes` (`XS/S/M: 5`, `L/XL: 12`, `XXL: 24` unless explicitly overridden with a positive integer).
- **Resume after interruption:** read `ledger.md`, run `review-ledger normalize` if legacy `SMALL|MEDIUM|LARGE|VERY_LARGE` sizes appear, run `review-ledger check` to identify `PENDING`/`INCOMPLETE`/`STALE` units invalidated by changed files, shared contracts, or risk changes, and re-run only invalidated/unreviewed units plus Level 3 when needed.
- Budget exhaustion, missing receipt/tool failure, stale unit, or incomplete ledger -> **`INCOMPLETE` or `BLOCKED`** (never `PASS` from silence).
