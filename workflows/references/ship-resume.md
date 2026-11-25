# Ship resume procedure (Scenario C)

Reconcile [`../ship.md`](../ship.md) checkpoints against Git before acting (progress files are claims, not proof).

## 1. Load checkpoint & verify Git identity

1. Resolve `{RUN_DIR}` via `b3-guard.{ps1,sh} resolve-run` (`<run_id>`, `.b3/ship/CURRENT`, `.b3/ship/progress.md`, or `.b3/autodev/`); write `<run_id>` to `CURRENT` on `runs/` runs; never scan sibling dirs.
2. Load `master-plan.md`, `progress.md`, active `findings.md`, and `approach/T00N.md` **only** for `in_progress`/next ready `pending` tasks (skip `completed`).
3. Verify `B3_HOME`, `PRODUCT_ROOT`, `plan_id`, `branch`: mismatch → `BLOCKED`.

## 2. Verify completed & in-progress tasks

1. Task is `completed` **only** when its SHA is a valid `commit`, descends into `HEAD` (`git merge-base --is-ancestor <sha> HEAD`), is unique, descends from `task_base`/`run_base_sha`, and satisfies ACs (`verify-check` on matching tree; legacy `b3-verify-v1` → `VERIFY_STALE`).
2. For `in_progress` edits (including partial waves): check if `impl_agent` stays active (never duplicate active work); verify `mode`, `worker_root` (`check-worktree` if `ISOLATED_WRITES`), `task_base`, `scope`, verification, integration; reconcile shared dirty edits (`initial_dirty_paths` vs `scope` vs unexpected edits) before resuming/committing. Keep valid work (never `git reset`), run `verify-check` (`evidence/T00N.verify`), isolate failed/stale tasks while continuing unrelated eligible tasks, reconcile `last_wave:`, and fail closed (`BLOCKED`/`INCOMPLETE`) if ownership/state is missing.

## 3. Approach freshness

Reuse a `ready` approach **only** when:
- Master-plan `version` == approach `plan_version`
- Recomputed `task_spec_fingerprint` (`b3-guard fingerprint`) == stored
- `HEAD` descends from `task_base`; `watched_paths` exist (or new-file intent)
- `scripts/b3-guard.{ps1,sh} check-freshness` returns **`FRESH`**

Equivalent Git dirty-set check (excl. `.b3/ship/` & unchanged `initial_dirty_paths`):

```text
git diff --name-only {approach_at_sha} HEAD
git diff --name-only {approach_at_sha}
git diff --cached --name-only
git ls-files --others --exclude-standard
```

- `git diff --name-only {approach_at_sha} HEAD` checks commits only; `git diff --name-only {approach_at_sha}` includes the working tree against that tree.
- Committed `watched_paths` or uncommitted `read_only_deps` (`watched_paths` minus `files`) edits are **stale** → re-run `Scope` for **this task only** (keep uncommitted `files` edits). Missing freshness fields also re-run `Scope`.

## 4. Continue ready work

Re-evaluate ready tasks (`pending`/`in_progress`, `depends_on` done) via `check-wave -Partition` (`-ProtectedPaths`, `-IgnoreDirtyPaths`, `-CheckDirtyScope`; act strictly on `wave|N|...`, or resume lowest-id sequentially; keep `blocked` blocked) and continue into `Build`.
