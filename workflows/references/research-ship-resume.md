# Research Ship Resume & Status (Scenario C)

Reconcile [`../research-ship.md`](../research-ship.md) checkpoints with Git, source digests, and branch/PR state.

## 1. Status (`status [<run_id>|--all]`) — Read-Only

1. Run `b3 guard list-runs --namespace research-ship` (`--all`) or `b3 guard resolve-run --namespace research-ship [--run-id <id>]`.
2. Read `{RUN_DIR}/progress.md`; report `run_id`, `mode`, units, blockers, `pr_number`, `merge_status`, `run_status`, and next unit (0 edits).

## 2. Resume (`resume [<run_id>]`)

1. Resolve `{RUN_DIR}` via `b3 guard resolve-run --namespace research-ship [--run-id <id>]`.
2. Load `progress.md`, active `U00N` in `research-plan.md`, `evidence-index.md`, and active findings (`OPEN`/`FIXED`) — skip completed logs.
3. Verify identity (`B3_HOME`, `PRODUCT_ROOT`, `branch`; mismatch → `BLOCKED`); confirm `run_base_sha` descends into `HEAD` (`git merge-base --is-ancestor`).
4. **Source freshness:** `b3 guard evidence-check --manifest-path <rel>` (+ `--source-paths` if changed): `EVIDENCE_FRESH` (`exit 0`) keeps verified work; `EVIDENCE_STALE` (`exit 2`) re-runs Phase D/E only for stale sources; `EVIDENCE_MISSING` (`exit 1`) stops unit `INCOMPLETE`/`BLOCKED`.
5. **Unit & branch/PR reconciliation:**
   - Check if `subagent_id` stays active (never duplicate active work). Verify `exec_mode`, `worker_root` (`b3 guard check-worktree --require-isolated` on `ISOLATED_WRITES`), `base_sha`, `scope`, verification, `integration`, task SHAs (`git merge-base --is-ancestor`), and `b3 guard verify-check`.
   - Reconcile dirty edits (`initial_dirty_paths` vs `scope` vs unexpected via `dispatch-naming.md`); isolate failed/stale units while keeping valid work and continuing eligible units (`BLOCKED`/`INCOMPLETE` on missing state).
   - If `pr_number` is set (or optional `gh pr list --head <branch>` finds an open PR on GitHub), inspect live PR/CI without opening duplicates; otherwise reconcile local branch state.
6. Re-evaluate ready units via `b3 guard check-wave --partition` (`--protected-paths`, `--ignore-dirty-paths`, `--check-dirty-scope`), reconcile `last_wave:`, and resume eligible `in_progress`/`pending` units (keeping `blocked` domain units untouched).
