# Autodev resume procedure (Scenario C)

Reconciliation protocol for [`../autonomous-development.md`](../autonomous-development.md) when resuming an interrupted `/autodev` run. Progress files are claims, not proof — verify against Git before acting.

## 1–4. Load checkpoint and verify Git identity

1. Read `.b3/autodev/master-plan.md`, `progress.md`, `findings.md` (if it exists), and `approach/*.md` (if they exist). Approach notes are decisions, not a second master plan.
2. Resolve `B3_HOME` and `PRODUCT_ROOT`. If `progress.md` records `b3_home` or `plan_id` and they do not match the current plan file and B3 location → `BLOCKED`.
3. Read branch, `HEAD`, ancestry, and `git status --porcelain`.
4. If `progress.md` records `branch` and the current branch differs → `BLOCKED`. Do not continue on the wrong branch.

## 5–8. Verify completed and in-progress tasks

5. Treat a task as `completed` only when **all** of these hold:
   - The recorded commit SHA exists (`git cat-file -t <sha>` is `commit`)
   - It is an ancestor of `HEAD` (`git merge-base --is-ancestor <sha> HEAD`)
   - It is unique among completed task SHAs in this run
   - It is a descendant of that task's `task_base` (or of `run_base_sha` if `task_base` was not recorded)
   - The commit's tree still supports the task acceptance criteria, or those checks are re-run and pass
6. SHA existence alone is not completion. A SHA on another branch, rewritten off `HEAD`, or reused for two tasks is not completion. Inspect the tree before doing the work again.
7. If the current task has uncommitted changes → inspect them. Keep valid work. Do not reset, and do not start a second copy of the same change.
8. Re-run the quality gate for an `in_progress` task before trusting it.

## 9. Approach freshness

Reuse a `ready` approach only when **all** of these hold:

- Current master-plan `version` equals the approach's recorded `plan_version`
- Recompute `task_spec_fingerprint` (via `scripts/autodev-guard.{ps1,sh} fingerprint` or canonical form `depends_on=<ids comma-sorted or []>|scope=<trimmed scope>|acceptance_criteria=<criteria joined with ; >`) and verify it equals the stored fingerprint
- `HEAD` is a descendant of `task_base`
- Paths in `watched_paths` (`files` + `read_only_deps`) still exist, or were explicit new-file intents not yet created
- Run `scripts/autodev-guard.{ps1,sh} check-freshness` (or the 4 Git queries below) and confirm **FRESH**

Manual / equivalent Git dirty-set check (exclude ignored `.b3/autodev/` paths and unchanged `initial_dirty_paths`):

```text
git diff --name-only {approach_at_sha} HEAD
git diff --name-only {approach_at_sha}
git diff --cached --name-only
git ls-files --others --exclude-standard
```

- `git diff --name-only {approach_at_sha} HEAD` is commits only.
- `git diff --name-only {approach_at_sha}` includes the working tree against that tree.
- Staged and untracked files are the other two commands.
- Logical contract names (`OrderCreated`) are **not** paths and do not participate in this intersection.
- Unrelated dirty files (not in `watched_paths`) do **not** invalidate.
- Any path in `git diff --name-only {approach_at_sha} HEAD` that is also in `watched_paths` is stale, including this task's `files` (a later commit moved the tree the approach was written against).
- The in-progress exception applies only to **uncommitted** dirty paths (working tree, staged, untracked) in `files`: keep that work (step 7); it does not by itself invalidate the approach.
- Uncommitted dirty `read_only_deps` (`watched_paths` not in `files`, e.g., inspected dependency or contract) **are** stale → re-run `Analyze`.
- If any required field (`watched_paths`, `reuse`, `obsoletes`, `task_spec_fingerprint`, or `approach_at_sha`) is missing or any freshness check fails → re-run `Analyze` for **this task only**. Do not write a new master plan. Do not implement from a stale approach.

## 10. Resume ready work

Resume the lowest-id `in_progress` task whose dependencies are `completed`. If none, take the lowest-id ready `pending` task. Leave `blocked` tasks blocked until the recorded blocker is resolved. If the approach is fresh and implementation had not started, **continue into Implement** in this session without waiting for a new user command.

Do not repeat a task that meets the completion tests above. Do not create a second commit for the same completed task.
