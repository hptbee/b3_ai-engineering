# Ship resume procedure (Scenario C)

Reconcile [`../ship.md`](../ship.md) checkpoints against Git before acting (progress files are claims, not proof).

## 1. Load checkpoint & verify Git identity

1. Resolve `{RUN_DIR}` via `b3-guard.{ps1,sh} resolve-run` (`<run_id>`, `.b3/ship/CURRENT`, `.b3/ship/progress.md`, or `.b3/autodev/` fallback); write `<run_id>` to `.b3/ship/CURRENT` on `.b3/ship/runs/` runs; never scan sibling dirs.
2. Read `{RUN_DIR}/master-plan.md`, `progress.md`, active (`OPEN`/unverified `FIXED`) `findings.md` items, and `approach/T00N.md` **only** for `in_progress`/next ready `pending` tasks — never `completed` `approach/*.md`.
3. Verify `B3_HOME`, `PRODUCT_ROOT`, `plan_id`, `branch`: mismatch → `BLOCKED`.

## 2. Verify completed & in-progress tasks

1. Task is `completed` **only** when its recorded SHA is a valid `commit`, descends into `HEAD` (`git merge-base --is-ancestor <sha> HEAD`), is unique here, descends from `task_base`/`run_base_sha`, and satisfies ACs (reuse `verify-check` across forward ancestry when relevant paths stay unchanged, else re-run checks).
2. For `in_progress` uncommitted edits: keep valid work (never `git reset`/duplicate); run `verify-check` on `{RUN_DIR}/evidence/T00N.verify` or re-verify.

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

Resume the lowest-id ready `in_progress` task (else ready `pending`; keep `blocked` blocked) and continue straight into `Build` without waiting for another command.
