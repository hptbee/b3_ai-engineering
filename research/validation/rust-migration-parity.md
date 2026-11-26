# Rust Migration Parity & Differential Validation Report

## Evidence Provenance & Classification

- **Immutable Legacy Baseline**: `65eaaaeb275ee1ce89c57d6fdd78ac3f3c1932fe` (`65eaaae`, pre-migration PowerShell + Bash + Node.js implementation)
- **Rust Binary Under Test**: `target/release/b3.exe` (branch `refactor/system-wide-deduplication`, post-Wave 8 + PR #34 remediation)
- **Capture Platform**: `Windows_NT / PS 5.1.26100.9818`
- **Captured At**: `2026-11-26T14:35:32Z`
- **Capture Harness**: `.b3/ship/runs/20261126-1155-system-wide-deduplication/scratch/capture-legacy-parity.ps1` (executed against isolated detached checkout `$env:TEMP\b3-legacy-oracle-65eaaae` and identical temp fixtures per case, then oracle worktree removed cleanly via `git worktree remove --force`)
- **Committed Golden Fixture**: [`tests/fixtures/legacy_baseline_65eaaae.json`](../../tests/fixtures/legacy_baseline_65eaaae.json) (47 cases across all 10 high-risk contract families)
- **Cross-Platform Golden Suite**: [`tests/native_golden_parity.rs`](../../tests/native_golden_parity.rs) (loads `legacy_baseline_65eaaae.json` via `b3::json::parse_json`, zero PowerShell dependency on Linux/macOS)

### Honest Verification Labels

| Label | Meaning & Scope |
| --- | --- |
| `INDEPENDENT_LEGACY_PARITY` | Executed side-by-side against immutable `65eaaae` legacy PowerShell/Node oracle and native `target/release/b3.exe` on identical isolated temp fixtures: **42 / 47** cases matched identically in exit code, normalized stdout, and on-disk artifacts. |
| `INTENTIONAL_BEHAVIOR_CHANGE` | Executed side-by-side against `65eaaae` oracle and `target/release/b3.exe`, with an intentional, documented delta (**5 / 47** cases). |
| `NATIVE_CONTRACT_VERIFIED` | Cross-platform golden contract assertions encoded in `tests/native_golden_parity.rs` comparing live `b3` output against `legacy_baseline_65eaaae.json` (unified `cargo test` run by coordinator in Step 2 and CI matrix). |
| `WRAPPER_FORWARDING_VERIFIED` | Thin wrapper dispatch checks in [`tests/wrapper_forwarding_windows.rs`](../../tests/wrapper_forwarding_windows.rs) and `unix_shell_wrapper_forwarding` in `tests/native_golden_parity.rs`. **Never** counted as independent differential testing (both shells invoke `b3`). |
| `NOT_VERIFIED` | Live external GitHub PR API mutations (PR feedback exercised against isolated mock `gh` `.cmd` fixture); native Linux/macOS binary execution pending CI matrix. |

## Normalization Rules

Only genuinely nondeterministic per-run values were normalized during differential capture:

1. **Isolated temp paths**: `<PROD_ROOT>`, `<B3_HOME>`, `<WT_ROOT>`, `<COMMON_DIR>`, `<SYNC_ROOT>`, `<STATE_LOCK_L>`, `<STATE_LOCK_R>`, with Windows `\` and forward `/` variants normalized per temp run.
2. **Dynamic Git commit SHAs**: `<HEAD_SHA>`, `<TRUNK_SHA>`, `<BASE_SHA>`, `<OLD_HEAD_SHA>`, `<SNAP_CLEAN_SHA>` mapped dynamically per temp repository; deterministic Git **tree hashes** (e.g. `c4582b65d0ba`, `077754575fa4`, `2a1b4ba3...`, `aa3d4435...`) were **not** normalized and were asserted identical between legacy and Rust.
3. **Timestamps & durations**: ISO-8601 UTC timestamps (`<ISO_UTC>`) and `verify-run` `duration_ms=<DURATION_MS>`.
4. **Derived operation hashes & host/PID lock metadata**: `operation_hash` / `;op=` (`<OP_HASH>`, which hashes dynamic `<HEAD_SHA>`) and live lock diagnostics `(host=<LOCK_HOST>, pid=<LOCK_PID>, state=ALIVE)`.

## Summary by Contract Family

| # | Contract Family | Cases | `INDEPENDENT_LEGACY_PARITY` | `INTENTIONAL_BEHAVIOR_CHANGE` |
| --- | --- | --- | --- | --- |
| 1 | Tree & task fingerprints | 4 | 3 | 1 |
| 2 | Verification receipts | 6 | 6 | 0 |
| 3 | Review ledger | 4 | 4 | 0 |
| 4 | Worktree & wave ownership | 6 | 6 | 0 |
| 5 | Merge eligibility | 4 | 3 | 1 |
| 6 | Protected & secret paths | 5 | 3 | 2 |
| 7 | Context cache & evidence freshness | 6 | 6 | 0 |
| 8 | PR feedback state, locking & idempotency | 9 | 8 | 1 |
| 9 | Installer ownership | 3 | 3 | 0 |
| 10 | Exit codes, normalized outputs & artifacts | All 47 | 42 | 5 |

## Full Per-Case Differential Comparison Table

| Family | Case ID | Label | Legacy Exit | Rust Exit | Output Match | Artifact Check | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1. Fingerprints | `fp_canonical` | `INDEPENDENT_LEGACY_PARITY` | `0` | `0` | Exact | `none` | Canonical task fingerprint ordering and delimiters |
| 1. Fingerprints | `fp_empty_depends` | `INDEPENDENT_LEGACY_PARITY` | `0` | `0` | Exact | `none` | Empty JSON array sentinel `[]` normalizes to `depends_on=[]` |
| 1. Fingerprints | `fp_missing_scope` | `INTENTIONAL_BEHAVIOR_CHANGE` | `1` | `1` | Intentional delta | `none` | Flag syntax normalized: legacy `-Scope` vs native `--scope` |
| 1. Fingerprints | `snap_clean_vs_dirty` | `INDEPENDENT_LEGACY_PARITY` | `0` | `0` | Exact | Clean tree `2a1b4ba3...`, dirty tree `aa3d4435...` equal; stash empty | Clean vs dirty snapshot commits match tree hashes and leave stash empty |
| 2. Receipts | `verify_run_schema` | `INDEPENDENT_LEGACY_PARITY` | `0` | `0` | Exact | `treeHashMatch=True`, `receiptMatch=True` | `verify-run` stdout and `b3-verify-v1` receipt fields/tree hash match |
| 2. Receipts | `verify_check_valid` | `INDEPENDENT_LEGACY_PARITY` | `0` | `0` | Exact | `none` | `verify-check` validates clean matching working tree |
| 2. Receipts | `verify_check_cmd_mismatch` | `INDEPENDENT_LEGACY_PARITY` | `1` | `1` | Exact | `none` | Fails closed on `--expected-cmd` mismatch |
| 2. Receipts | `verify_check_stale` | `INDEPENDENT_LEGACY_PARITY` | `2` | `2` | Exact | `none` | Detects working-tree mutation after receipt (`tree=c4582b65d0ba -> 077754575fa4`) |
| 2. Receipts | `verify_check_target_commit_sha_valid` | `INDEPENDENT_LEGACY_PARITY` | `0` | `0` | Exact | `none` | Validates against matching `--target-commit-sha` |
| 2. Receipts | `verify_check_target_commit_sha_mismatch` | `INDEPENDENT_LEGACY_PARITY` | `1` | `1` | Exact | `none` | Rejects invalid/missing `--target-commit-sha` |
| 3. Ledger | `ledger_init_independent` | `INDEPENDENT_LEGACY_PARITY` | `0` | `0` | Exact | `.b3/ship/ledger.md` created | `review-ledger init` with `INDEPENDENT` |
| 3. Ledger | `ledger_update_with_receipt` | `INDEPENDENT_LEGACY_PARITY` | `0` | `0` | Exact | `none` | `review-ledger update` bound to `.b3/ship/u1.verify` |
| 3. Ledger | `ledger_check_valid` | `INDEPENDENT_LEGACY_PARITY` | `0` | `0` | Exact | `none` | `LEDGER_GATE_PASS` with `review_independence=INDEPENDENT` |
| 3. Ledger | `ledger_check_single_agent_limit` | `INDEPENDENT_LEGACY_PARITY` | `0` | `0` | Exact | `none` | `LEDGER_GATE_PASS` with `review_independence=SINGLE_AGENT_LIMIT` (`SELF_REVIEW` rejected by both with exit 1) |
| 4. Worktree/Wave | `check_worktree_isolated` | `INDEPENDENT_LEGACY_PARITY` | `0` | `0` | Exact | `none` | Isolated linked worktree with peer roots passes |
| 4. Worktree/Wave | `check_worktree_peer_overlap_blocked` | `INDEPENDENT_LEGACY_PARITY` | `2` | `2` | Exact | `none` | Rejects overlapping peer root (`parent_root_reused_or_nested`) |
| 4. Worktree/Wave | `check_wave_disjoint` | `INDEPENDENT_LEGACY_PARITY` | `0` | `0` | Exact | `none` | Disjoint wave specs emit `WAVE_OK: disjoint (3 tasks, 2 paths)` |
| 4. Worktree/Wave | `check_wave_partition` | `INDEPENDENT_LEGACY_PARITY` | `0` | `0` | Exact | `none` | `--partition --max-concurrency 2` splits into 2 waves (`WAVE_PARTITIONED`) |
| 4. Worktree/Wave | `check_wave_sequential` | `INDEPENDENT_LEGACY_PARITY` | `2` | `2` | Exact | `none` | Conflicting tasks emit `WAVE_SEQUENTIAL` with exit 2 |
| 4. Worktree/Wave | `check_freshness_fresh` | `INDEPENDENT_LEGACY_PARITY` | `0` | `0` | Exact | `none` | Matching base SHA emits `FRESH` |
| 5. Merge Policy | `merge_policy_local_authorized` | `INDEPENDENT_LEGACY_PARITY` | `0` | `0` | Exact | `none` | Authorizes local merge with valid receipt + independent ledger |
| 5. Merge Policy | `merge_policy_caller_ci_pass_without_receipt_blocked` | `INDEPENDENT_LEGACY_PARITY` | `1` | `1` | Exact | `none` | Blocks caller-reported `CI=PASS` without verify receipt |
| 5. Merge Policy | `merge_policy_stale_ledger_blocked` | `INDEPENDENT_LEGACY_PARITY` | `1` | `1` | Exact | `none` | Blocks merge when commit advances past ledger/receipt |
| 5. Merge Policy | `merge_policy_inprocess_pr_verify` | `INTENTIONAL_BEHAVIOR_CHANGE` | `2` | `1` | Intentional delta | `none` | Wave 8: Rust executes `crate::pr::verify::run` in-process with zero Node.js dependency |
| 6. Protected/Secret | `snapshot_secret_env_blocked` | `INDEPENDENT_LEGACY_PARITY` | `1` | `1` | Exact | `none` | Blocks untracked `.env` secret path |
| 6. Protected/Secret | `merge_policy_protected_unicode_space_bracket_add` | `INTENTIONAL_BEHAVIOR_CHANGE` | `1` | `1` | Intentional delta | `none` | Both exit `1` blocking `releases/v1 [draft] café/new.txt`; Rust emits UTF-8 on redirected pipes vs PS5.1 ANSI `caf` |
| 6. Protected/Secret | `merge_policy_protected_rename_out` | `INTENTIONAL_BEHAVIOR_CHANGE` | `1` | `1` | Intentional delta | `none` | Both exit `1` blocking `releases/v1 [draft] café/secret.txt`; Rust emits UTF-8 on redirected pipes vs PS5.1 ANSI `caf` |
| 6. Protected/Secret | `precommit_allowed_paths_fail` | `INDEPENDENT_LEGACY_PARITY` | `1` | `1` | Exact | `none` | Blocks undeclared staged path (`PRECOMMIT_FAIL`) |
| 6. Protected/Secret | `precommit_allowed_paths_pass` | `INDEPENDENT_LEGACY_PARITY` | `0` | `0` | Exact | `none` | Passes with declared allowed path and valid verify receipt (`PRECOMMIT_OK`) |
| 7. Cache/Evidence | `context_cache_record` | `INDEPENDENT_LEGACY_PARITY` | `0` | `0` | Exact | `.b3/ship/ctx.cache` created | Records `b3-context-v1` cache artifact |
| 7. Cache/Evidence | `context_cache_check_fresh` | `INDEPENDENT_LEGACY_PARITY` | `0` | `0` | Exact | `none` | `CONTEXT_FRESH` on unchanged anchor/scope paths |
| 7. Cache/Evidence | `context_cache_check_stale` | `INDEPENDENT_LEGACY_PARITY` | `2` | `2` | Exact | `none` | `CONTEXT_STALE` (`reasons=anchor_changed`) after modifying `docs/guide.md` |
| 7. Cache/Evidence | `evidence_check_write` | `INDEPENDENT_LEGACY_PARITY` | `0` | `0` | Exact | `.b3/ship/ev.manifest` created | Writes `b3-evidence-v1` manifest |
| 7. Cache/Evidence | `evidence_check_fresh` | `INDEPENDENT_LEGACY_PARITY` | `0` | `0` | Exact | `none` | `EVIDENCE_FRESH` on unmodified source path |
| 7. Cache/Evidence | `evidence_check_stale` | `INDEPENDENT_LEGACY_PARITY` | `2` | `2` | Exact | `none` | `EVIDENCE_STALE: docs/guide.md` after modifying `docs/guide.md` |
| 8. PR Feedback | `pr_fetch` | `INDEPENDENT_LEGACY_PARITY` | `0` | `0` | Exact | `none` | Sanitized untrusted PR framing and thread counts match |
| 8. PR Feedback | `pr_reply_draft` | `INDEPENDENT_LEGACY_PARITY` | `0` | `0` | Exact | `none` | `PR_DRAFT_OK` preview & marker format match |
| 8. PR Feedback | `pr_reply_post` | `INDEPENDENT_LEGACY_PARITY` | `0` | `0` | Exact | `.state.json` created on both | `PR_REPLY_OK` and canonical `.state.json` persistence match |
| 8. PR Feedback | `pr_reply_idempotent_skip` | `INDEPENDENT_LEGACY_PARITY` | `0` | `0` | Exact | `none` | Identical repeat key/payload emits `PR_IDEMPOTENT_SKIP` |
| 8. PR Feedback | `pr_resolve` | `INDEPENDENT_LEGACY_PARITY` | `0` | `0` | Exact | `none` | Verifies receipt + evidence and emits `PR_RESOLVE_OK` |
| 8. PR Feedback | `pr_comment_both` | `INDEPENDENT_LEGACY_PARITY` | `0` | `0` | Exact | `none` | Posts summary + inline review comment (`PR_COMMENT_OK`) |
| 8. PR Feedback | `pr_lock_live_blocked` | `INDEPENDENT_LEGACY_PARITY` | `2` | `2` | Exact | `none` | Live lock PID blocks concurrent PR mutation (`PR_CONCURRENT_LOCK`) |
| 8. PR Feedback | `pr_lock_dead_reclaimed` | `INDEPENDENT_LEGACY_PARITY` | `0` | `0` | Exact | `none` | Dead-PID lock on same host is reclaimed and write succeeds |
| 8. PR Feedback | `pr_verify_zero_node` | `INTENTIONAL_BEHAVIOR_CHANGE` | `2` | `1` | Intentional delta | `none` | Wave 6/8: `b3 pr verify` runs natively with zero Node.js dependency |
| 9. Installers | `install_product_cursor` | `INDEPENDENT_LEGACY_PARITY` | `0` | `0` | Exact | `.b3/home`, `.cursor/commands/b3-ship.md`, `.gitignore` | Product pointer, managed command, and `.gitignore` match |
| 9. Installers | `install_product_codex` | `INDEPENDENT_LEGACY_PARITY` | `0` | `0` | Exact | `.b3/home`, `.agents/skills`, `.gitignore` | Product pointer, flat `.agents/skills` junctions, and `.gitignore` match |
| 9. Installers | `sync_skills_antigravity_verify_only` | `INDEPENDENT_LEGACY_PARITY` | `0` | `0` | Exact | `.agents/skills.json` + skill index | `verify ok` validates flat index and manifest |

## Intentional Behavior Changes (`INTENTIONAL_BEHAVIOR_CHANGE`)

1. **`fp_missing_scope`**: Legacy PowerShell reports `FINGERPRINT_FAIL: missing -Scope`, whereas the native CLI reports `FINGERPRINT_FAIL: missing --scope` to match POSIX/Rust CLI flags.
2. **`merge_policy_protected_unicode_space_bracket_add` & `merge_policy_protected_rename_out`**: Both legacy and Rust block protected Unicode/space/bracket paths (`releases/v1 [draft] café/...`) with exit `1`. On redirected Windows pipes, PowerShell 5.1 `[Console]::Out` emits ANSI/OEM bytes decoded as `caf`, whereas Rust `b3.exe` always writes valid UTF-8 (`café`).
3. **`pr_verify_zero_node`**: Legacy `scripts/b3-github-verify.ps1` exits `2` (`GH_VERIFY_UNAVAILABLE: node_runtime_unavailable`) when `node` is absent from `PATH`. Native `b3 pr verify` has zero Node.js dependency and invokes `gh` directly (`GH_VERIFY_ERROR: pr_number_mismatch` against minimal `{}` stub, exit `1`).
4. **`merge_policy_inprocess_pr_verify`**: Legacy `b3-guard.ps1 merge-policy-check` shelled out to `b3-github-verify.ps1` -> `node` (failing `PROVIDER_UNAVAILABLE: github_verification_failed(node_runtime_unavailable)` without Node.js). Wave 8 `b3 guard merge-policy-check` invokes `crate::pr::verify::run` in-process without Node.js or external helper scripts (`MERGE_BLOCKED: github_verification_failed(pr_number_mismatch)`, exit `1`).
