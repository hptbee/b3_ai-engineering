# Research Ship Resume & Status (Scenario C)

Reconcile [`../research-ship.md`](../research-ship.md) checkpoints with Git, source digests, and PR state.

## 1. Status (`status [<run_id>|--all]`) — Read-Only

1. Run `b3-guard.{ps1,sh} list-runs -Namespace research-ship` (if `--all`) or `resolve-run -Namespace research-ship [-RunId <id>]`.
2. Read `{RUN_DIR}/progress.md`; report `run_id`, `mode`, units, blockers, `pr_number`, `merge_status`, `run_status`, and next unit (0 edits).

## 2. Resume (`resume [<run_id>]`)

1. Resolve `{RUN_DIR}` via `b3-guard.{ps1,sh} resolve-run -Namespace research-ship [-RunId <id>]`.
2. Load `progress.md`, active `U00N` in `research-plan.md`, `evidence-index.md`, and active findings (`OPEN`/`FIXED`) — skip completed logs.
3. Verify identity (`B3_HOME`, `PRODUCT_ROOT`, `branch`; mismatch → `BLOCKED`). Confirm `run_base_sha` descends into `HEAD` (`git merge-base --is-ancestor`).
4. **Source freshness:** run `b3-guard.{ps1,sh} evidence-check -ManifestPath <rel>` (plus `-SourcePaths` when unit files changed):
   - `EVIDENCE_FRESH` (`exit 0`) → preserve verified research work.
   - `EVIDENCE_STALE` (`exit 2`) → mark affected units stale and re-run Phase D/E only for stale sources.
   - `EVIDENCE_MISSING` (`exit 1`) → stop unit at `INCOMPLETE` / `BLOCKED` until sources exist.
5. **Unit, implementation & PR reconciliation:**
   - Check if `subagent_id` remains active (never duplicate active work). Verify `exec_mode`, `worker_root` (`check-worktree` if `ISOLATED_WRITES`), `base_sha`, `scope`, verification, `integration`, task SHAs (`git merge-base --is-ancestor`), and `verify-check`.
   - Reconcile shared dirty edits (`initial_dirty_paths` vs `scope` vs unexpected edits) before resuming/committing; isolate failed/stale units while preserving valid work and continuing independent eligible units; fail closed (`BLOCKED`/`INCOMPLETE`) if ownership/state is unestablished.
   - If `pr_number` exists (or `gh pr list --head <branch>` finds open PR), inspect live PR state/CI/reviews; never open a duplicate PR.
6. Re-evaluate ready units via `check-wave -Partition` (`-ProtectedPaths`, `-IgnoreDirtyPaths`, `-CheckDirtyScope`), reconcile `last_wave:`, and resume next eligible `in_progress`/`pending` unit (keep `blocked` domain units untouched) without restarting completed work after compaction.
