# Autodev resume procedure (Scenario C)

Reconcile [`../autonomous-development.md`](../autonomous-development.md) checkpoints against Git before acting (progress files are claims, not proof).

## 1. Load checkpoint & verify Git identity

1. Resolve `{RUN_DIR}` via `scripts/autodev-guard.{ps1,sh} resolve-run` (from explicit `<run_id>`, `.b3/autodev/CURRENT`, or legacy `.b3/autodev/progress.md` fallback when `CURRENT` is absent). If explicit `<run_id>` was given and resolves, write `<run_id>` to `.b3/autodev/CURRENT`. Never scan sibling dirs under `.b3/autodev/runs/`.
2. Read `{RUN_DIR}/master-plan.md`, `progress.md`, `findings.md` (if present), and `approach/*.md` (if present).
3. Verify `B3_HOME`, `PRODUCT_ROOT`, `plan_id`, and `branch`: if `progress.md` mismatches current `plan_id`, `b3_home`, or active Git branch → `BLOCKED`.

## 2. Verify completed & in-progress tasks

1. Treat a task as `completed` **only** when its recorded SHA is a valid `commit`, is an ancestor of `HEAD` (`git merge-base --is-ancestor <sha> HEAD`), is unique in this run, descends from `task_base` (or `run_base_sha`), and its tree still satisfies ACs (or checks re-run green).
2. For an `in_progress` task with uncommitted edits: inspect and keep valid work (never `git reset` or duplicate edits); re-run the quality gate before trusting it.

## 3. Approach freshness

Reuse a `ready` approach **only** when:
- Master-plan `version` == approach `plan_version`
- Recomputed `task_spec_fingerprint` (`autodev-guard fingerprint`) == stored fingerprint
- `HEAD` descends from `task_base`, and `watched_paths` exist (or are explicit new-file intents)
- `scripts/autodev-guard.{ps1,sh} check-freshness` returns **`FRESH`**

Equivalent Git dirty-set check (excluding `.b3/autodev/` and unchanged `initial_dirty_paths`):

```text
git diff --name-only {approach_at_sha} HEAD
git diff --name-only {approach_at_sha}
git diff --cached --name-only
git ls-files --others --exclude-standard
```

- `git diff --name-only {approach_at_sha} HEAD` checks commits only; `git diff --name-only {approach_at_sha}` includes the working tree against that tree.
- Any committed change in `watched_paths`, or any uncommitted change in `read_only_deps` (`watched_paths` minus `files`), is **stale** → re-run `Analyze` for **this task only** (uncommitted edits in owned `files` are kept in-progress work, not stale). Missing freshness fields also require re-running `Analyze`.

## 4. Continue ready work

Resume the lowest-id ready `in_progress` task (else lowest-id ready `pending` task; leave `blocked` tasks blocked) and continue directly into `Implement` in this session without waiting for another command.
