# Ship resume procedure (Scenario C)

Reconcile [`../ship.md`](../ship.md) checkpoints against Git before acting (progress files are claims, not proof).

## 1. Load checkpoint & verify Git identity

1. Resolve `{RUN_DIR}` via `b3 guard resolve-run` (`<run_id>`, `.b3/ship/CURRENT`, or `.b3/ship/progress.md`); update `CURRENT` on `runs/` without scanning sibling dirs.
2. Load `master-plan.md`, `progress.md`, active `findings.md`, and `approach/T00N.md` **only** for `in_progress`/next ready `pending` tasks.
3. Verify `B3_HOME`, `PRODUCT_ROOT`, `plan_id`, `branch`: mismatch → `BLOCKED`.

## 2. Verify completed & in-progress tasks

1. Task is `completed` **only** when its SHA is a valid `commit`, descends into `HEAD` (`git merge-base --is-ancestor <sha> HEAD`), is unique, descends from `task_base`/`run_base_sha`, and passes `b3 guard verify-check` (legacy pre-v1 → `VERIFY_CORRUPT`; stale tree/HEAD → `VERIFY_STALE`).
2. For `in_progress` edits (including partial waves): check `impl_agent` (never duplicate active work); verify `mode`, `worker_root` (`b3 guard check-worktree --require-isolated` ONLY on `ISOLATED_WRITES`; pass `--worker-bases` to `mechanical-check` if isolated `task_base` lags `HEAD`), `task_base`, `scope`, verification, `integration` (`pending|output_ready|integrated`); reconcile dirty edits via `dispatch-naming.md`. Keep valid work (never `git reset`), run `verify-check`, isolate failed/stale tasks while continuing eligible tasks, reconcile `last_wave:`, and fail closed (`BLOCKED`/`INCOMPLETE`) on missing state.

## 3. Approach freshness

Reuse a `ready` approach **only** when:
- Plan `version` == `plan_version`, recomputed `task_spec_fingerprint` (`b3 guard fingerprint`, required on resume/handoff) == stored, `HEAD` descends from `task_base`, and `watched_paths` exist (or new-file intent)
- `b3 guard check-freshness --approach-at-sha {approach_at_sha} --task-base-sha {task_base} --watched-paths <csv> [--owned-files <csv>] [--ignore-dirty-paths <csv>]` returns **`FRESH`** (checks working-tree + index diffs vs `{approach_at_sha}`, not `HEAD` only)
- Any `STALE` or missing field re-runs `Scope` for **this task only** (keeping uncommitted `files` edits).

## 4. Continue ready work

Re-evaluate ready tasks (`depends_on` `output_ready`/`integrated`; keep `blocked` blocked): when `>=2` ready tasks or active `impl_agent` workers run, pass `--active-specs`, `--active-reads`, `--verified-dirty-paths`, `--check-dirty-scope` to `Build` `b3 guard check-wave --partition` (else resume 1 task/chain w/ scope/dirty/commit guards).
