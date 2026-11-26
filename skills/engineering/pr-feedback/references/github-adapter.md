# GitHub SCM Adapter (`b3-pr-github`)

Thin GitHub provider adapter for `skills/engineering/pr-feedback/SKILL.md`. Read-only PR inspection guidelines remain in [`github-pr-review.md`](../../code-review/references/github-pr-review.md); all PR feedback reads and authorized writes route through `b3 pr <fetch|reconcile|reply|resolve|comment>` (invoked directly or via `scripts/b3-pr-github.{ps1,sh}` compatibility shims).

## Prerequisites, Transport, State & Limitations

- Requires authenticated `gh` CLI (native `b3` binary requires no Node.js runtime; legacy `B3_USE_LEGACY=1` uses `node` with built-in modules only — zero npm packages, zero new MCP servers).
- **Safe transport & stdout:** All GraphQL queries/mutations and REST POSTs pass structured JSON via `gh api ... --input -` (`stdin`). Exit uses `process.exitCode` + natural stdout drain (never `process.exit()`, preventing pipe truncation).
- **Unified file & path guards:** Rejects symlinks/reparse points on leaf and ancestor directories, `..` traversal, UNC/mixed-slash `^[\\/]{2}`, drive-relative paths, ADS `:`, Windows reserved device names (`CON`, `NUL .`, `CON .txt`), oversized inputs (`>256 KiB` / `>65536` chars), and corrupt state JSON; strips UTF-8 BOM.
- **State, single writer & provider limits:** Enforces `thread-lifecycle.md` §4 & §6 via canonical `<git-common-dir>/b3/pr-feedback/<owner>__<repo>__pr-<pr>.state.json` (`--state-file` rejected, `PR_FILE_GUARD` outside git), `PR_MUTATION_OWNER_REQUIRED` (`git-dir != git-common-dir` or `B3_PR_MUTATION_ROLE=worker` / `B3_SUBAGENT=1`), PID/`ESRCH` + `.reclaim` lock, pre/post `OPEN`+`HEAD` checks, `<!-- b3-pr-key:<key>;op=<16hex> -->` revalidation, and explicit `reconcile`. Note: full clones or unflagged processes in the primary checkout share only local lockfile serialization.

## Subcommands & Flags

PowerShell: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/b3-pr-github.ps1 <cmd> ...`
Bash: `./scripts/b3-pr-github.sh <cmd> ...`

### 1. `fetch` (read-only; never clears pending state)
```text
fetch --repo <owner/repo> --pr <N> [--include-resolved] [--include-bodies] [--thread-id <id[,id...]>] [--max-pages <M>]
```
- Metadata-first default (`reviewThreads` with `totalCount`, omitting bodies/nested comment pages). `--thread-id` fetches only the named thread(s) via `node(id)`.
- Sanitizes all PR text (control/bidi/tag chars, delimiter breakout) inside `BEGIN_UNTRUSTED_PR_DATA` / `END_UNTRUSTED_PR_DATA`.

### 2. `reconcile` (pending-operation recovery)
```text
reconcile --repo <owner/repo> --pr <N> [--repo-root <dir>] [--max-pages <M>]
```
- Acquires the canonical PR lock and verifies every `PENDING` / `reconciliation_required` record against live remote objects (`verifyRemoteObject`), classifying `CONFIRMED_SUCCESS`, `CONFIRMED_ABSENCE`, `STALE_MUTATION`, or `UNCERTAIN`.
- Clears pending blocks only on `CONFIRMED_*` / `STALE_MUTATION`; exits `2` (`PR_RECONCILIATION_UNCERTAIN`) and keeps writes blocked when uncertain.

### 3. `reply`
```text
reply --repo <owner/repo> --pr <N> [--repo-root <dir>] --expected-head <sha> \
  --target-kind review_thread|general_comment --target-id <id> \
  --body-file <path> [--idempotency-key <key>] \
  [--authorize-write] [--draft] [--max-pages <M>]
```
- Targeted `node(id)` (`review_thread`) or `GET issues/comments/<id>` (`general_comment`, prepending `> Replying to [comment #<id>](<html_url>)`).
- Derives `<!-- b3-pr-key:<key>;op=<16hex> -->`, detects key collisions (`PR_KEY_COLLISION`), revalidates existing remote objects before skipping (`PR_REMOTE_STATE_MISMATCH` on edit), rechecks `OPEN` + `HEAD` pre-write, posts (never resolves), and verifies the created remote object + `HEAD` + `OPEN`.

### 4. `resolve`
```text
resolve --repo <owner/repo> --pr <N> [--repo-root <dir>] --expected-head <sha> \
  --thread-id <id> --fix-commit <sha> --evidence-file <path> \
  [--authorize-resolve] [--draft] [--max-pages <M>]
```
- Reuses canonical `scripts/b3-guard.{ps1,sh} verify-check` against exact remote PR `HEAD`, `evidence.checked_command`, verified paths, and receipt `head_sha`, **plus** enforces clean non-ignored index/working tree (preserving gitignored `.b3/{ship,research-ship,autodev}/` checkpoints) and exact committed `ls-tree` manifest hash match against `expected_head` (`COMMIT_TREE` check).
- Verifies remote `thread.path == evidence.target_path`, `DUPLICATE_FIXED` `primary_thread_id` resolved remotely, remote `compare` ancestry (`identical|ahead`, `behind_by == 0`), and `GET commits/<fix_commit>` modifying all verified paths.
- Rechecks remote `OPEN` + `HEAD` **and** exact-commit local verification immediately before `resolveReviewThread`, then verifies `isResolved == true`, ownership, `OPEN`, and `HEAD`.

### 5. `comment`
```text
comment --repo <owner/repo> --pr <N> [--repo-root <dir>] --expected-head <sha> \
  --mode summary|inline|both [--event COMMENT|APPROVE|REQUEST_CHANGES] \
  [--summary-file <path>] [--inline-json <path>] [--idempotency-key <key>] \
  [--authorize-write] [--authorize-review-event APPROVE|REQUEST_CHANGES] \
  [--draft] [--max-pages <M>]
```
- Validates `--inline-json` (`CONFIRMED`, `CRITICAL|HIGH|MEDIUM|LOW`, positive line, `RIGHT|LEFT`) against live `pulls/<pr>/files` AND strict unified diff hunk line counts/completeness (`PR_DIFF_UNAVAILABLE` if truncated/malformed/missing; `PR_INVALID_ANCHOR` if outside hunks).
- Revalidates actor-scoped candidates before `PR_IDEMPOTENT_SKIP` (rejecting dismissed/edited/mismatched reviews), rechecks `OPEN` + `HEAD` pre-write, posts, and re-verifies the created object, review state, commit SHA, inline `path:line:side:body`, `OPEN`, and `HEAD`.

## Exit Codes

- `0`: `PR_FETCH_OK`, `PR_RECONCILE_OK`, `PR_DRAFT_OK`, `PR_REPLY_OK`, `PR_RESOLVE_OK`, `PR_COMMENT_OK`, `PR_IDEMPOTENT_SKIP`, `PR_ALREADY_RESOLVED`.
- `1`: `PR_INVALID_ARGS`, `PR_TARGET_MISMATCH`, `PR_NOT_RESOLVABLE`, `PR_INVALID_ANCHOR`, `PR_FILE_GUARD`, `PR_POST_WRITE_UNVERIFIED`, `PR_API_ERROR`.
- `2`: `PR_AUTH_REQUIRED`, `PR_EVENT_UNAUTHORIZED`, `PR_MUTATION_OWNER_REQUIRED`, `PR_NOT_OPEN`, `PR_STALE_HEAD`, `PR_VERIFY_REQUIRED`, `PR_FIX_NOT_REMOTE`, `PR_DIFF_UNAVAILABLE`, `PR_KEY_COLLISION`, `PR_REMOTE_STATE_MISMATCH`, `PR_CONCURRENT_LOCK`, `PR_RECONCILIATION_REQUIRED`, `PR_RECONCILIATION_UNCERTAIN`, `PR_PAGINATION_INCOMPLETE`, `PR_POST_WRITE_HEAD_MOVED`.
