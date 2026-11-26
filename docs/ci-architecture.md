# B3 CI Architecture, Baseline & Test Ownership

> Canonical reference for B3's dependency-aware CI pipeline, test deduplication ownership matrix, and local preflight verification.

## 1. Baseline Profiling (Before Optimization)

### GitHub Actions Baseline

Measured from PR #34 (`45862631722`, `refactor/system-wide-deduplication`) and `main` (`45865751325`, commit `cedf068`):

| Job / Step | `ubuntu-latest` (`45862631722` / `45865751325`) | `macos-latest` (`45862631722` / `45865751325`) | `windows-latest` (`45862631722` / `45865751325`) |
| --- | --- | --- | --- |
| Checkout + Rust toolchain | 11s / 15s | 13s / 8s | 19s / 19s |
| `cargo fmt` + `cargo clippy` | 3s / 3s | 5s / 3s | 9s / 5s |
| `cargo build --release` | 31s / 32s | 43s / 51s | 57s / 39s |
| `cargo test` | 27s / 28s | 30s / 29s | 116s / 85s |
| Context budget + evals | 0s / 0s | 1s / 0s | 1s / 1s |
| `validate-merge-security.sh` | 83s / 100s | 104s / 104s | 275s / 196s |
| Windows PS behavioral suites (seq) | skipped | skipped | 415s (fail) / 299s (fail) |
| **Total job runtime** | **159s / 183s** | **202s / 201s** | **899s / 648s** |

- **Total CI compute minutes (`45862631722`)**: ~`2.65 + 3.37 + 14.98 = 21.0` min (plus `Release Binaries` running on every PR commit: `4.6` min across 4 runners).
- **Critical path**: `windows-latest` (`899s` execution + `269s` runner queue = `1168s` wall-clock).
- **Time-to-first-actionable-failure**: Up to `15` minutes when a Windows behavioral suite fails at the end of the sequential loop.

### Local Windows Per-Suite Baseline

Measured sequentially in worktree `refactor/native-ci-optimization` (`cedf068`, release `b3.exe` prebuilt):

| Suite | LOC | Measured (s) | Primary Responsibility | Duplication / Opportunity |
| --- | --- | --- | --- | --- |
| `validate-ship-behavior.ps1` | 3356 | 389.23 | `/b3-ship` guard + adapter + doc contracts | ~75% `DUPLICATE_EQUIVALENT` core `b3` checks via PS/Bash wrappers |
| `validate-tshirt-hierarchical.ps1` | 1194 | 350.41 | `diff-scope`, `review-inventory`, `review-ledger` | ~90% `DUPLICATE_EQUIVALENT` deterministic `b3` checks + 25k-LOC synthetic repos |
| `validate-research-ship.ps1` | 1215 | 164.87 | `/b3-research-ship` evidence, merge-policy, isolation | ~70% `DUPLICATE_EQUIVALENT` core `b3` checks |
| `validate-context-routing.ps1` | 702 | 115.71 | `context-cache`, `sync-skills`, routing doc contracts | ~65% `DUPLICATE_EQUIVALENT` `context-cache` state machine checks |
| `cargo test` | — | 97.36 | Rust unit + `native_golden_parity` + `wrapper_forwarding_windows` + `bootstrap_lifecycle` | `wrapper_forwarding_windows.rs` (3158 L) spawns ~70 `powershell` + ~94 `b3.exe` + 17 `git init` |
| `validate-standalone-commands.ps1` | 580 | 52.73 | Standalone command receipts, `verify-run`, doc caps | ~75% `DUPLICATE_EQUIVALENT` core `b3` checks |
| `validate-antigravity-global.ps1` | 1020 | 33.93 | Antigravity plugin + `install-global` lifecycle | ~60% `DUPLICATE_EQUIVALENT` manifest/install logic |
| `validate-pr-feedback.ps1` | 1221 | 31.49 | `b3 pr` lifecycle, locks, pipe, `b3-github-verify` | ~70% `DUPLICATE_EQUIVALENT` `b3 pr` logic (Blocks 1–9) |
| `validate-cursor-global.ps1` | 604 | 23.49 | Cursor global install + junction safety | ~60% `DUPLICATE_EQUIVALENT` manifest/install logic |
| `validate-model-preferences.ps1` | 182 | 7.79 | `models.example.md`, seeding, `.gitignore` dedup | ~60% doc contracts + ~25% wrapper parity |
| `smoke-ship-product.ps1` | 190 | 6.64 | E2E `/b3-ship` product repo smoke | `UNIQUE_REQUIRED` E2E smoke |
| `measure-context.ps1 -Strict` | 42 | 0.17 | Always-on/skill context budget | `UNIQUE_REQUIRED` fast gate |

## 2. Test Coverage Ownership Matrix

| Test Group | Classification | Canonical Owner | Kept in Scripts / Non-Rust? |
| --- | --- | --- | --- |
| `b3` deterministic core (`fingerprint`, `snapshot`, `precommit`, `diff-scope`, `review-inventory`, `review-ledger`, `check-wave`, `check-worktree`, `mechanical-check`, `symbol-check`, `context-cache`, `evidence-check`, `merge-policy-check`, `runs`, `verify-*`) | `DUPLICATE_EQUIVALENT` in PS/Bash scripts | `src/` unit tests + `tests/native_golden_parity.rs` + `tests/native_core_behaviors.rs` | No — migrated to Rust; scripts keep only wrapper-forwarding smoke |
| Legacy baseline 47-case JSON replay (`legacy_baseline_65eaaae.json`) | `INDEPENDENT_LEGACY_PARITY` | `tests/native_golden_parity.rs` | No |
| `b3 pr` protocol, hunk, lock, idempotency, bidi sanitization | `DUPLICATE_EQUIVALENT` (Blocks 1–9 of `validate-pr-feedback.ps1`) | `src/pr/*` + `tests/native_core_behaviors.rs` | `validate-pr-feedback.ps1` keeps wrapper parity, large OS pipe (`>250KiB`), POSIX `gh`, Win32 `CON .txt` |
| Windows PS wrapper arg forwarding, quoting, trailing `\`, exit codes, `B3_BIN` | `WRAPPER_COMPATIBILITY` | `tests/wrapper_forwarding_windows.rs` (focused) + thin script wrapper checks | Focused smoke only (~1–2 cases per wrapper) |
| Unix Bash wrapper arg forwarding, `MSYS2_ARG_CONV_EXCL`, `cygpath` | `WRAPPER_COMPATIBILITY` | `tests/native_golden_parity.rs` (`unix_shell_wrapper_forwarding`) + `validate-merge-security.sh` | Focused dual-shell checks |
| NTFS junctions, `core.filemode`/`autocrlf`, Win32 `CON .txt`/ADS, `Add-Type` fake `git.exe`, POSIX extensionless `gh` | `PLATFORM_SPECIFIC` | Windows PS/Bash platform suites + `src/fs.rs`/`src/adapters/common.rs` | Yes — kept in slimmed PS/Bash suites |
| `bootstrap-b3.{ps1,sh}` SHA-256, in-use upgrade, rollback, lock, symlink/junction guards | `UNIQUE_REQUIRED` | `tests/bootstrap_lifecycle.rs` | No (already Rust-driven) |
| Markdown/YAML/eval/context-budget contracts (`AGENTS.md`, `rules/`, `workflows/`, `skills/`, `evals/*.yaml`) | `UNIQUE_REQUIRED` | `measure-context` + `validate-evals.sh` + slimmed PS doc-contract checks | Yes — fast static checks |
| Adversarial `merge-policy-check` + `b3-github-verify` dual-shell + mock-`gh` | `UNIQUE_REQUIRED` + `WRAPPER_COMPATIBILITY` | `validate-merge-security.sh` + Rust unit/integration tests | `validate-merge-security.sh` keeps dual-shell + mock-`gh` + `file://` remote |

## 3. Target Dependency-Aware CI Architecture

```text
fast-gate (ubuntu-latest, <2m)
  ├── cargo fmt --check
  ├── cargo clippy --all-targets -- -D warnings
  ├── measure-context.sh --strict + validate-evals.sh
  └── cargo test --lib
         │
         ├──► linux-verify (ubuntu-latest): cargo build --release + cargo test + validate-merge-security.sh
         ├──► macos-verify (macos-latest):  cargo build --release + cargo test + validate-merge-security.sh
         └──► windows-build (windows-latest): cargo build --release + cargo test + upload b3.exe
                   │
                   ├──► windows-suites [shard: security]   (validate-merge-security.sh w/ B3_BIN)
                   └──► windows-suites [shard: behavioral] (slimmed PS wrapper/platform/doc suites w/ B3_BIN)
         │
         ▼
ci-gate (if: always()) — requires every upstream job result == 'success' (never passes on skip/cancel/fail)
```

### Controls
- `concurrency`: cancels superseded PR/branch runs immediately.
- `timeout-minutes`: explicit per-job timeouts (`fast-gate: 10`, `linux/macos-verify: 15`, `windows-build: 15`, `windows-suites: 15`).
- `release.yml`: runs on tags `v*.*.*`, `workflow_dispatch`, or PRs touching Rust/bootstrap/release files (skipped on docs/script-only PRs).
- **Local Preflight**: Run `.\scripts\ci-preflight.ps1` (Windows) or `./scripts/ci-preflight.sh` (Unix) before pushing.
