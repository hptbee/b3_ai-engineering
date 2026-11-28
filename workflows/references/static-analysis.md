# Adaptive Static Analysis & Offloading Contract (On-Demand)

Canonical workflow contract for project-native static analysis, dead-code verification, safe auto-fix boundaries, baseline attribution, and mechanical offloading (`0 B` always-on context cost). Heavy analysis is `WORKFLOW_ONLY` ([`hook-integration.md`](hook-integration.md)).

## 1. Project-Native Tool Discovery (Parent-Once, Untrusted-Safe)

Parent runs discovery **once** during Preflight / before parallel dispatch (`ship.md`, `research-ship.md`, `feature-implementation.md`) and passes the resolved command/scope hint to workers—never repeat discovery inside every worker.

1. **Verified repo scripts & lint configs:** inspect manifests/configs read-only (`package.json`, `Cargo.toml`, `pyproject.toml`, `.eslintrc*`, `ruff.toml`, `clippy.toml`) before running; never blindly execute unreviewed third-party PR scripts or plugins.
2. **Language toolchain defaults:** `cargo clippy`, `tsc --noEmit`, `ruff check`, `go vet`, `dotnet build`.
3. **B3 native deterministic guards:** `b3 guard mechanical-check`, `b3 guard symbol-check`, `b3 guard verify-check` (with `src/guard/mechanical.rs` and `src/guard/symbol.rs` authoritative).
4. **No-lint progressive fallback:** `REUSE` existing repo tools → `FALLBACK` compiler/typecheck + `mechanical-check` + `symbol-check` with zero config churn → `BOOTSTRAP` new lint config **only** when explicitly authorized by task/user.
5. **Ecosystem security & boundary checks (when present):** dependency audits (`cargo audit`, `npm audit`), SAST/secret scans, circular-dep, or layer analyzers.

## 2. 4-Level Dead Code & Production-Consumer Verification

| Level | Scope | Typical Signal / Tool |
| --- | --- | --- |
| `L1` | Local / private unused | Unused locals, params, private helpers, unused imports (compiler/linter) |
| `L2` | Module-internal unreferenced | Package/module orphans (`SYMBOL_ADVISORY` `orphan_internal`, internal lints) |
| `L3` | Exported / public API unreferenced | Workspace-wide unreferenced exports/symbols (`symbol-check`, TS/Rust/Go/Python refs) |
| `L4` | Unreachable / dead config / unused deps | Unreachable branches, stale flags/configs, unused deps (`cargo udeps`/`machete`, `knip`, `depcheck`) |

- **Production-consumer verification (mandatory before deletion or blocking flag):** `unit tests != runtime/production caller`. Grep runtime entrypoints (`src/`, `bin/`, exports, DI/reflection/FFI) separately from test references before deleting or flagging `L2`/`L3` symbols.
- Pair compiler/linter output with `b3 guard symbol-check` fallback cleanly: `SYMBOL_ADVISORY` (`orphan_internal`) is non-blocking; `SYMBOL_FINDINGS` (`dangling_refs`) blocks (`exit 2`) unless a proven textual false positive is documented.

## 3. Duplicates, Complexity, Security & Architecture Boundaries

- Offload token/AST duplicates, cyclomatic/cognitive complexity, SAST/secret scans, and circular/layer dependency checks to existing project tools + `b3 guard mechanical-check` (`safety_hits`, `advisory_hits`, `obsolete_hits`) first.
- Distinguish accidental bloat / `CONFIRMED REDUNDANCY` from justified `INTENTIONAL COMPLEXITY` per [`residue-checklist.md`](../../skills/engineering/code-review/references/residue-checklist.md); never flag complexity on line count alone.

## 4. Scoped Safe Auto-Fix Boundaries

- Run auto-fix **only** inside explicitly writable owned `allowed-paths`: **never** in read-only `/b3-audit` or `/b3-review` mode, **never** across overlapping wave paths, and **never** before `check-wave --partition` verification.
- Allow safe deterministic fixes only (formatting, unused imports, safe lint `--fix` without dirty-tree masking).
- **Never** silence warnings via suppressions (`eslint-disable`, `@ts-ignore`, `#[allow(...)]` without concrete rationale) or speculative behavioral rewrites.
- **Receipt invalidation:** any auto-fix edit (including lint/analyzer config edits tracked by `src/guard/verify.rs`) invalidates prior `b3-verify-v1` receipts (`VERIFY_STALE`) — run auto-fixes **before** final `b3 guard verify-run` / final test & build verification.

## 5. Baseline-Aware Verification (Regression Attribution)

- Never treat raw warning count deltas (`200 -> 195`) as regression-free (`10` fixed + `5` new = `5` introduced regressions).
- Track touched-file / diff-line attribution or pre/post fingerprints:
  - **Diff-introduced regressions:** block `PASS`.
  - **Unchanged pre-existing warnings:** report separately as `PREEXISTING_BASELINE` (never conflate with clean or diff-caused defects).

## 6. Mechanical Review Offloading & Guard Consolidation Boundary

- **Pre-review offload:** run deterministic checks (`verify-check`/`verify-run`, `mechanical-check`, `symbol-check`, native lint/SAST/boundary tools) **before** dispatching AI reviewers. Hand reviewers a compact evidence digest (`tool: pass/fail + touched regression counts + PREEXISTING_BASELINE`) so `b3-reviewer`, `b3-security-reviewer`, and `b3-architecture-reviewer` skip mechanical trivia and focus on semantics, trust boundaries, architecture, and runtime risk.
- **Hook vs workflow boundary:** keep `b3 hook` Tier 0 (`p95 < 10 ms`) and Tier 1 fast precommit/push hooks strictly free of heavy linters; keep `src/guard/mechanical.rs` and `src/guard/symbol.rs` as the single authoritative deterministic guard implementations.
