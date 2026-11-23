# Research Ship Resume & Status (Scenario C)

Reconcile [`../research-ship.md`](../research-ship.md) checkpoints against Git, source fingerprints, and PR state before continuing.

## 1. Status (`status [<run_id>|--all]`) — Read-Only

1. Run `b3-guard.{ps1,sh} list-runs -Namespace research-ship` (if `--all`) or `resolve-run -Namespace research-ship [-RunId <id>]`.
2. Read `{RUN_DIR}/progress.md` and report `run_id`, `mode`, unit statuses, active blockers, `pr_number`, `merge_status`, `run_status`, and next eligible unit without modifying files.

## 2. Resume (`resume [<run_id>]`)

1. Resolve `{RUN_DIR}` via `b3-guard.{ps1,sh} resolve-run -Namespace research-ship [-RunId <id>]`.
2. Load `{RUN_DIR}/progress.md`, active `U00N` items in `research-plan.md`, `evidence-index.md`, and active review findings (`OPEN`/unverified `FIXED`) — skip completed verified unit logs.
3. Verify identity (`B3_HOME`, `PRODUCT_ROOT`, `branch`; mismatch → `BLOCKED`). Confirm `run_base_sha` descends into `HEAD` (`git merge-base --is-ancestor`).
4. **Source freshness:** run `b3-guard.{ps1,sh} evidence-check -ManifestPath <rel>` (plus `-SourcePaths` when unit files changed):
   - `EVIDENCE_FRESH` (`exit 0`) → preserve verified research work.
   - `EVIDENCE_STALE` (`exit 2`) → mark affected units stale and re-run Phase D/E only for stale sources.
   - `EVIDENCE_MISSING` (`exit 1`) → stop unit at `INCOMPLETE` / `BLOCKED` until sources exist.
5. **Implementation & PR reconciliation:**
   - Check recorded task SHAs (`git merge-base --is-ancestor`) and `b3-guard verify-check` if code receipts exist.
   - If `pr_number` exists (or `gh pr list --head <branch>` finds an open PR), inspect live PR state/CI/reviews instead of opening a duplicate PR.
6. Resume the lowest-id eligible `in_progress` or `pending` unit (leaving `blocked` domain units isolated and untouched) without restarting completed work after context compaction.
