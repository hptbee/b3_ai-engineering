# Ship resume procedure (Scenario C)

Reconcile [`../ship.md`](../ship.md) checkpoints against Git before acting (progress files are claims, not proof).

## 1. Load checkpoint & verify Git identity

1. Resolve `{RUN_DIR}` via `scripts/b3-guard.{ps1,sh} resolve-run` (explicit `<run_id>`, `.b3/ship/CURRENT`, or legacy `.b3/ship/progress.md`). Write explicit `<run_id>` to `CURRENT`. Never scan sibling dirs under `.b3/ship/runs/`.
2. Read `{RUN_DIR}/master-plan.md`, `progress.md`, active (`OPEN`/unverified `FIXED`) items in `findings.md` (if present), and `approach/T00N.md` **only** for `in_progress` or next ready `pending` tasks — **never** load `approach/*.md` of `completed` tasks.
3. Verify `B3_HOME`, `PRODUCT_ROOT`, `plan_id`, and `branch`: if `progress.md` mismatches current `plan_id`, `b3_home`, or active Git branch → `BLOCKED`.

## 2. Verify completed & in-progress tasks

1. Treat a task as `completed` **only** when its recorded SHA is a valid `commit`, is an ancestor of `HEAD` (`git merge-base --is-ancestor <sha> HEAD`), is unique in this run, descends from `task_base` (or `run_base_sha`), and its tree still satisfies ACs (or checks re-run green).
2. For an `in_progress` task with uncommitted edits: inspect and keep valid work (never `git reset` or duplicate edits); re-run the quality gate before trusting it.

## 3. Approach freshness

Reuse a `ready` approach **only** when:
- Master-plan `version` == approach `plan_version`
- Recomputed `task_spec_fingerprint` (`b3-guard fingerprint`) == stored
- `HEAD` descends from `task_base`; `watched_paths` exist (or new-file intent)
- `scripts/b3-guard.{ps1,sh} check-freshness` returns **`FRESH`**

Equivalent Git dirty-set check (excluding `.b3/ship/` and unchanged `initial_dirty_paths`):

```text
git diff --name-only {approach_at_sha} HEAD
git diff --name-only {approach_at_sha}
git diff --cached --name-only
git ls-files --others --exclude-standard
```

- `git diff --name-only {approach_at_sha} HEAD` checks commits only; `git diff --name-only {approach_at_sha}` includes the working tree against that tree.
- Committed changes in `watched_paths` or uncommitted changes in `read_only_deps` (`watched_paths` minus `files`) are **stale** → re-run `Scope` for **this task only** (uncommitted edits in `files` are kept, not stale). Missing freshness fields also require re-running `Scope`.

## 4. Continue ready work

Resume the lowest-id ready `in_progress` task (else lowest-id ready `pending` task; leave `blocked` tasks blocked) and continue directly into `Build` in this session without waiting for another command.
