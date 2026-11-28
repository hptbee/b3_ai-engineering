# Adaptive Static Analysis & Offloading Contract (On-Demand)

Conditional workflow contract for static analysis, dead-code checks, safe auto-fix, baseline attribution, and mechanical offloading (`0 B` always-on; load **only when** code analysis, verify, auto-fix, review, refactor, audit, or impl applies — skip in pure `/b3-plan`, `/b3-research`, `/b3-pr-{comment,reply}`). Heavy checks stay `WORKFLOW_ONLY` ([`hook-integration.md`](hook-integration.md)).

## 1. Project-Native Discovery & Adaptive Scope (Parent-Once, Untrusted-Safe)

Parent runs discovery **once** in Preflight / before parallel dispatch (`ship.md`, `research-ship.md`, `feature-implementation.md`) and passes the resolved command/scope hint to workers—never rediscover inside every worker.

1. **Verified repo scripts & configs:** inspect manifests/configs read-only before running; never blindly execute unreviewed third-party PR scripts or plugins.
2. **Toolchain defaults:** `cargo clippy`, `tsc --noEmit`, `ruff check`, `go vet`, `dotnet build`.
3. **B3 deterministic guards:** `mechanical-check`, `symbol-check`, `verify-check` (`src/guard/{mechanical,symbol,verify}.rs`).
4. **Progressive fallback:** `REUSE` existing tools → `FALLBACK` compiler/typecheck + `mechanical-check` + `symbol-check` with zero config churn → `BOOTSTRAP` new config **only** when explicitly authorized by task/user.
5. **Security & boundary analyzers (when present):** `cargo audit`/`npm audit`, SAST/secret scans, circular/layer checks.

- **Adaptive scope (T-shirt size × risk/dependency impact):** `XS`: relevant changed files; `S`: changed symbols & consumers; `M`: affected modules; `L`: affected packages; `XL`: repository-wide if needed; `XXL`: repository-wide + architecture. Risk or dependency impact widens scope; mandatory CI checks always stay enabled.
- **Coverage-gap rule:** invoke specialized analyzers and B3 `symbol-check` fallback **only** when native compiler/linter leaves a real coverage gap or task requires refactor/symbol checks—never duplicate checks already covered cleanly.

## 2. 4-Level Dead Code & Production-Consumer Verification

| Level | Scope | Typical Signal / Tool |
| --- | --- | --- |
| `L1` | Local / private unused | Unused locals/params/helpers/imports (compiler/linter) |
| `L2` | Module-internal unreferenced | Module/package orphans (`SYMBOL_ADVISORY` `orphan_internal`, internal lints) |
| `L3` | Exported / public API unreferenced | Workspace unreferenced exports (`symbol-check`, workspace refs) |
| `L4` | Unreachable / dead config / unused deps | Dead branches/flags/configs, unused deps (`cargo udeps`/`machete`, `knip`, `depcheck`) |

- **Production-consumer verification (before deletion or blocking flag):** `unit tests != runtime/production caller`. Grep runtime entrypoints (`src/`, `bin/`, exports, DI/reflection/FFI) separately from tests before flagging/deleting `L2`/`L3` symbols. Pair with `symbol-check`: `SYMBOL_ADVISORY` non-blocking; `SYMBOL_FINDINGS` (`dangling_refs`) blocks (`exit 2`) unless proven textual FP.

## 3. Duplicates, Complexity, Security & Architecture Boundaries

- Offload AST/token duplicates, cyclomatic/cognitive complexity, SAST/secret scans, and circular/layer checks to project tools + `mechanical-check` (`safety_hits`, `advisory_hits`, `obsolete_hits`) first.
- Distinguish `CONFIRMED REDUNDANCY` from `INTENTIONAL COMPLEXITY` ([`residue-checklist.md`](../../skills/engineering/code-review/references/residue-checklist.md)); never flag complexity on LOC alone.

## 4. Scoped Safe Auto-Fix & Receipt Closure

- **Execution-mode safety:**
  - `Inline / Sequential`: enforce existing `allowed-paths` (no `check-wave` required).
  - `Shared Disjoint Writes`: require `check-wave --partition` + ownership verification.
  - `Isolated Writes`: require `check-worktree` + ownership verification.
  - `Read-only` (`/b3-audit`, `/b3-review`): **no auto-fix**.
- **Pre-run scoped mutation:** verify the tool accepts explicit file/path targets before running in shared WTs; run repo-wide mutators only in `ISOLATED_WRITES` or quiescent `SEQUENTIAL` mode (post-run `git diff` alone cannot undo overwritten peer edits).
- Apply deterministic fixes only (formatting, unused imports, safe lint `--fix`); **never** add warning suppressions without concrete rationale or run speculative behavioral rewrites.
- **Receipt closure:** built-in matchers in `src/guard/verify.rs` are **supplementary protection only**, not proof of full input closure. Parent MUST list all verification inputs (lint/ignore configs, imported custom configs, custom lint scripts) in `--relevant-paths`, or omit `--relevant-paths` (`ALL`) whenever dependency/config closure cannot be proven. Auto-fix edits invalidate prior receipts (`VERIFY_STALE`) → run before final `verify-run`.

## 5. Narrow Baseline Policy (Exit-0 Warnings ≠ Regression-Free)

- Distinguish **command exit `0` ≠ zero regressions**: inspect diff-introduced warnings/diagnostics even when a linter exits `0` if policy forbids new warnings.
- Ignore **only** unrelated, unchanged, non-blocking legacy `PREEXISTING_BASELINE` findings; **always** act on findings impacting security, correctness, required CI checks, or acceptance criteria. Do not bypass mandatory CI checks or introduce a standalone baseline DB.

## 6. Mechanical Review Offloading & Review Loop Sync

- **Pre-review offload:** run deterministic checks (`verify-run`/`verify-check`, `mechanical-check`, native lint/SAST/boundary, `symbol-check` on refactors/gaps) before AI reviewers; pass compact digest (`tool: pass/fail + new regressions + PREEXISTING_BASELINE`) so AI reviewers skip trivia and inspect semantics, security, architecture, and runtime risk.
- **Review Loop (`review-loop/strategy.md`):** Iter 1 reuses fresh Parent lint digest on same tree/`HEAD`/scope; Iter 2+ re-runs affected-scope lint on `delta_files`+configs (widening on config/risk/boundary changes), skipping duplicate analyzers.
- **Hook boundary:** keep `b3 hook` Tier 0 (`p95 < 10 ms`) and Tier 1 fast hooks free of heavy linters; keep `mechanical.rs` and `symbol.rs` authoritative.
