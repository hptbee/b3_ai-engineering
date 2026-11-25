# Ship resume procedure (Scenario C)

Reconcile [`../ship.md`](../ship.md) checkpoints against Git before acting (progress files are claims, not proof).

## 1. Load checkpoint & verify Git identity

1. Resolve `{RUN_DIR}` via `b3-guard.{ps1,sh} resolve-run` (`<run_id>`, `.b3/ship/CURRENT`, `.b3/ship/progress.md`, or `.b3/autodev/`); update `CURRENT` on `runs/` without scanning sibling dirs.
2. Load `master-plan.md`, `progress.md`, active `findings.md`, and `approach/T00N.md` **only** for `in_progress`/next ready `pending` tasks.
3. Verify `B3_HOME`, `PRODUCT_ROOT`, `plan_id`, `branch`: mismatch → `BLOCKED`.

## 2. Verify completed & in-progress tasks

1. Task is `completed` **only** when its SHA is a valid `commit`, descends into `HEAD` (`git merge-base --is-ancestor <sha> HEAD`), is unique, descends from `task_base`/`run_base_sha`, and passes `verify-check` (legacy `b3-verify-v1` → `VERIFY_STALE`).
2. For `in_progress` edits (including partial waves): check `impl_agent` (never duplicate active work); verify `mode`, `worker_root` (`check-worktree -RequireIsolated`), `task_base`, `scope`, verification, integration; reconcile dirty edits via `dispatch-naming.md`. Keep valid work (never `git reset`), run `verify-check`, isolate failed/stale tasks while continuing eligible tasks, reconcile `last_wave:`, and fail closed (`BLOCKED`/`INCOMPLETE`) on missing state.

## 3. Approach freshness

Reuse a `ready` approach **only** when:
- Plan `version` == `plan_version`, recomputed `task_spec_fingerprint` (`b3-guard fingerprint`) == stored, `HEAD` descends from `task_base`, and `watched_paths` exist (or new-file intent)
- `b3-guard.{ps1,sh} check-freshness -ApproachAtSha {approach_at_sha} -TaskBaseSha {task_base} -WatchedPaths <csv> [-OwnedFiles <csv>] [-IgnoreDirtyPaths <csv>]` (Bash: `--task-base-sha <sha> --owned-files <csv>`) returns **`FRESH`** (unlike `HEAD`-only diffs, `git diff --name-only {approach_at_sha}` includes the working tree against that tree)
- Any `STALE` result or missing field re-runs `Scope` for **this task only** (keeping uncommitted `files` edits).

## 4. Continue ready work

Re-evaluate ready tasks via `check-wave -Partition` (`-ProtectedPaths`, `-IgnoreDirtyPaths`, `-CheckDirtyScope`; act on `wave|N|...`, or resume lowest-id sequentially; keep `blocked` blocked) and continue into `Build`.
