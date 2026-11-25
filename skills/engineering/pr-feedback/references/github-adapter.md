# GitHub SCM Adapter (`b3-pr-github`)

Thin GitHub provider adapter for `skills/engineering/pr-feedback/SKILL.md`. Read-only PR inspection guidelines remain in [`skills/engineering/code-review/references/github-pr-review.md`](../../code-review/references/github-pr-review.md); all GitHub PR feedback reads and authorized writes route through `scripts/b3-pr-github.{ps1,sh}` (thin shims over `scripts/lib/b3-pr-github.mjs`).

## Prerequisites & Transport

- Requires authenticated `gh` CLI and Node.js (`node`, built-in modules only — zero npm packages, zero new MCP servers).
- **Safe transport:** Every GraphQL query/mutation and REST POST sends structured JSON strictly via `gh api ... --input -` on `stdin`. User/PR text NEVER enters shell strings, GraphQL interpolation, or `gh api -F` (`@file`) arguments.
- **Fail closed:** Missing `gh`/auth, missing `node`, closed/merged PR, stale HEAD, unpushed fix, missing authorization, or truncated pagination exits non-zero without mutating remote state.

## Subcommands & Flags

PowerShell: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/b3-pr-github.ps1 <cmd> ...`
Bash: `./scripts/b3-pr-github.sh <cmd> ...`

### 1. `fetch` (read-only)
```text
fetch --repo <owner/repo> --pr <N> [--include-resolved] [--include-bodies] [--max-pages <M>]
```
- Paginates `reviewThreads` (100/page), nested `reviewThread.comments` (100/page), and REST `issues/<pr>/comments` (100/page). Default `--max-pages 20`.
- **Always untrusted-sanitized & framed:** Both default metadata-first output (`title`, `baseRef`, `headRef`, `path`, `authors`) and `--include-bodies` output (`prBody`, comment bodies) strip non-whitespace control chars, Unicode bidi overrides/isolates, and Unicode tag chars, neutralize delimiter-breakout tokens, and wrap untrusted text in `BEGIN_UNTRUSTED_PR_DATA` / `END_UNTRUSTED_PR_DATA`.
- Default omits comment and PR bodies to minimize context; `--include-bodies` adds the framed bodies.

### 2. `reply`
```text
reply --repo <owner/repo> --pr <N> --expected-head <sha> \
  --target-kind review_thread|general_comment --target-id <id> \
  --body-file <path> [--idempotency-key <key>] \
  [--authorize-write] [--draft] [--state-file <path>]
```
- Requires `--authorize-write` (else `PR_AUTH_REQUIRED`, exit `2`) unless `--draft` (zero-write preview). Combining `--draft` with `--authorize-write` fails closed (`PR_INVALID_ARGS`, exit `1`).
- Verifies remote PR `state == OPEN`, `headRefOid == expected_head`, and `target_id` belongs to `<repo>#<pr>`.
- Scans authenticated actor (`viewer.login`) comments on the exact target for `<!-- b3-pr-key:<key> -->`; skips cleanly with `PR_IDEMPOTENT_SKIP` (exit `0`) if already posted.
- Uses GraphQL `addPullRequestReviewThreadReply` for `review_thread` and REST `POST repos/<repo>/issues/<pr>/comments` for `general_comment`. Never resolves threads.
- Re-queries remote state post-write to verify comment creation and `headRefOid == expected_head`.

### 3. `resolve`
```text
resolve --repo <owner/repo> --pr <N> --expected-head <sha> \
  --thread-id <id> --fix-commit <sha> --verify-status PASS|FAIL|INCOMPLETE \
  [--authorize-resolve] [--draft] [--state-file <path>]
```
- Requires `--authorize-resolve` (else `PR_AUTH_REQUIRED`, exit `2`) unless `--draft`. Combining `--draft` with `--authorize-resolve` fails closed (`PR_INVALID_ARGS`, exit `1`).
- Requires `--verify-status PASS`, PR `state == OPEN`, `headRefOid == expected_head`, and `thread_id` being a `review_thread` belonging to `<repo>#<pr>` (rejects general comments with `PR_NOT_RESOLVABLE`).
- Proves `--fix-commit` is reachable in remote PR `HEAD` via `repos/<repo>/compare/<fix_commit>...<headRefOid>` (`status` in `identical|ahead` and `behind_by == 0`, else `PR_FIX_NOT_REMOTE`).
- If thread is already resolved, returns `PR_ALREADY_RESOLVED` (exit `0`).
- Calls GraphQL `resolveReviewThread`, then re-queries remote thread + PR `HEAD` to confirm `isResolved == true` and `headRefOid == expected_head`.

### 4. `comment`
```text
comment --repo <owner/repo> --pr <N> --expected-head <sha> \
  --mode summary|inline|both [--event COMMENT|APPROVE|REQUEST_CHANGES] \
  [--summary-file <path>] [--inline-json <path>] [--idempotency-key <key>] \
  [--authorize-write] [--authorize-review-event APPROVE|REQUEST_CHANGES] \
  [--draft] [--state-file <path>]
```
- Requires `--authorize-write` (else `PR_AUTH_REQUIRED`, exit `2`) unless `--draft`. Combining `--draft` with `--authorize-write` or `--authorize-review-event` fails closed (`PR_INVALID_ARGS`, exit `1`).
- Default `--event COMMENT`. Non-`COMMENT` events require BOTH `--authorize-write` AND `--authorize-review-event <EVENT>` matching `--event` exactly (`PR_EVENT_UNAUTHORIZED`, exit `2`).
- Verifies remote PR `state == OPEN` and `headRefOid == expected_head` before posting.
- Validates `--inline-json` entries strictly: `status == "CONFIRMED"`, `severity` in `CRITICAL|HIGH|MEDIUM|LOW`, non-empty `title`/`body`/`suggested_fix`, `line >= 1`, `side` in `RIGHT|LEFT`, and `path` present in paginated live PR changed files (`pulls/<pr>/files`).
- Scans authenticated actor's existing reviews and issue comments (paginated) for `<!-- b3-pr-key:<key> -->` before posting.
- Posts via `POST repos/<repo>/issues/<pr>/comments` (`summary` with `COMMENT`) or `POST repos/<repo>/pulls/<pr>/reviews` (`inline`, `both`, or non-`COMMENT` event) bound to `commit_id = expected_head`, then re-queries remote state to confirm created review/comment ID and `headRefOid == expected_head`.

## File Guards & Exit Codes

- Input files (`--body-file`, `--summary-file`, `--inline-json`): regular files only (no symlinks/directories), `<= 256 KiB`; comment bodies `<= 65536` chars. `--state-file`: rejects `..` traversal and symlinks.
- Exit `0`: success (`PR_FETCH_OK`, `PR_DRAFT_OK`, `PR_REPLY_OK`, `PR_RESOLVE_OK`, `PR_COMMENT_OK`, `PR_IDEMPOTENT_SKIP`, `PR_ALREADY_RESOLVED`).
- Exit `1`: invalid args/identifiers (`PR_INVALID_ARGS`), target/PR mismatch (`PR_TARGET_MISMATCH`), non-resolvable comment (`PR_NOT_RESOLVABLE`), file guard (`PR_FILE_GUARD`), runtime/API failure (`PR_API_ERROR`).
- Exit `2`: blocked gate (`PR_AUTH_REQUIRED`, `PR_EVENT_UNAUTHORIZED`, `PR_NOT_OPEN`, `PR_STALE_HEAD`, `PR_VERIFY_REQUIRED`, `PR_FIX_NOT_REMOTE`, `PR_PAGINATION_INCOMPLETE`, `PR_POST_WRITE_HEAD_MOVED`).
