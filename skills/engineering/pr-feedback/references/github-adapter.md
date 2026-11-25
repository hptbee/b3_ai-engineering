# GitHub SCM Adapter (`b3-pr-github`)

Thin GitHub provider adapter for `skills/engineering/pr-feedback/SKILL.md`. Read-only PR inspection guidelines remain in [`github-pr-review.md`](../../code-review/references/github-pr-review.md); all PR feedback reads and authorized writes route through `scripts/b3-pr-github.{ps1,sh}` (thin shims over `scripts/lib/b3-pr-github.mjs`).

## Prerequisites, Transport & Safety

- Requires authenticated `gh` CLI and `node` (built-in modules only — zero npm packages, zero new MCP servers).
- **Safe transport & stdout:** GraphQL queries/mutations and REST POSTs send JSON strictly via `gh api ... --input -` on `stdin` (never `-F` or shell-interpolated PR text). Exit sets `process.exitCode` and drains `process.stdout` naturally (no `process.exit()` pipe truncation).
- **Unified file guards:** Input files (`--body-file`, `--summary-file`, `--inline-json`, `--evidence-file`, `verify_receipt_path`) and `--state-file` reject symlinks/reparse points on leaf and ancestor directories (while preserving legitimate OS temp dirs), `..` traversal, drive-relative paths, ADS (`:`), Windows device names, oversized files (`>256 KiB` / `>65536` chars), and strip leading UTF-8 BOM.
- **Provider limits (honesty):** GitHub APIs do not provide server-side idempotency keys or atomic check-HEAD-and-mutate transactions. Pre-write rechecks, client lockfiles, actor-scoped markers, and post-write object verification minimize duplicates and detect races deterministically, but cannot guarantee server-side atomicity or exactly-once delivery.

## Subcommands & Flags

PowerShell: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/b3-pr-github.ps1 <cmd> ...`
Bash: `./scripts/b3-pr-github.sh <cmd> ...`

### 1. `fetch` (read-only, metadata-first or targeted)
```text
fetch --repo <owner/repo> --pr <N> [--include-resolved] [--include-bodies] [--thread-id <id[,id...]>] [--max-pages <M>] [--state-file <path>]
```
- Default is metadata-first (paginated `reviewThreads` using `totalCount` + REST `issues/<pr>/comments`, omitting bodies/nested comment pages).
- `--thread-id <id[,id...]>` fetches full paginated comments/bodies ONLY for the named review thread(s) via `node(id: ...)` without scanning the entire PR.
- All untrusted PR text (`title`, refs, `body`, `path`, `authors`, comment bodies) strips non-whitespace control chars, Unicode bidi overrides/isolates, and Unicode tag chars, breaks delimiter-breakout substrings, and wraps in `BEGIN_UNTRUSTED_PR_DATA` / `END_UNTRUSTED_PR_DATA`.
- With `--state-file`, reconciles prior `reconciliation_required` records after inspecting fresh remote state.

### 2. `reply`
```text
reply --repo <owner/repo> --pr <N> --expected-head <sha> \
  --target-kind review_thread|general_comment --target-id <id> \
  --body-file <path> [--idempotency-key <key>] \
  [--authorize-write] [--draft] [--state-file <path>] [--max-pages <M>]
```
- Requires `--authorize-write` (else `PR_AUTH_REQUIRED`) unless `--draft` (`--draft` + `--authorize-*` fails `PR_INVALID_ARGS`).
- Uses targeted single-thread GraphQL `node(id)` (`review_thread`) or `GET issues/comments/<id>` (`general_comment`, automatically prepending a permalink/reference to the original comment).
- Always embeds `<!-- b3-pr-key:<key>;op=<16hex> -->` (auto-derived if omitted), checks actor-scoped idempotency + `PR_KEY_COLLISION`, rechecks `OPEN` + `HEAD` immediately before write, posts reply (never resolves), then re-fetches and verifies the actual created comment object, actor, target, content, and `HEAD`.

### 3. `resolve`
```text
resolve --repo <owner/repo> --pr <N> --expected-head <sha> \
  --thread-id <id> --fix-commit <sha> --evidence-file <path> \
  [--authorize-resolve] [--draft] [--state-file <path>] [--max-pages <M>]
```
- Bare `--verify-status PASS` is rejected. Requires `--evidence-file` (`schema=b3-pr-verify-evidence-v1`) bound to `repo`, `pr`, `expected_head`, `thread_id`, `fix_commit`, `target_path`, `resolution_basis` (`CONFIRMED_FIXED|ALREADY_FIXED|DUPLICATE_FIXED`), and a valid passing `b3-verify-v1` receipt (`status=PASS`, `exit_code=0`, `head_sha == expected_head`, relevant paths covering target/fix paths).
- Uses targeted `node(id)` lookup (rejecting general comments with `PR_NOT_RESOLVABLE` and cross-PR threads with `PR_TARGET_MISMATCH`), verifies `evidence.target_path == thread.path`, proves remote `fix_commit` ancestry (`compare` `identical|ahead`, `behind_by == 0`) **and** proves `GET commits/<fix_commit>` modified the target/declared fix paths.
- Rechecks `OPEN` + `HEAD` immediately before `resolveReviewThread`, then re-queries remote thread ownership, `isResolved == true`, and `HEAD`.

### 4. `comment`
```text
comment --repo <owner/repo> --pr <N> --expected-head <sha> \
  --mode summary|inline|both [--event COMMENT|APPROVE|REQUEST_CHANGES] \
  [--summary-file <path>] [--inline-json <path>] [--idempotency-key <key>] \
  [--authorize-write] [--authorize-review-event APPROVE|REQUEST_CHANGES] \
  [--draft] [--state-file <path>] [--max-pages <M>]
```
- Default `--event COMMENT`. Non-`COMMENT` events require both `--authorize-write` and matching `--authorize-review-event <EVENT>`.
- Validates `--inline-json` (`status == CONFIRMED`, `CRITICAL|HIGH|MEDIUM|LOW`, non-empty `title`/`body`/`suggested_fix`, `line >= 1`, `side in RIGHT|LEFT`) against paginated `pulls/<pr>/files` **and** actual unified diff hunk anchors (`PR_DIFF_UNAVAILABLE` if patch missing/truncated; `PR_INVALID_ANCHOR` if line/side outside hunks).
- Enforces mandatory/derived `key` + `op` hash (`PR_KEY_COLLISION` on mismatch), immediate pre-write `OPEN` + `HEAD` recheck, and full post-write object verification (re-fetching created issue comment or pull review + review comments, actor, commit SHA, state, body, inline anchors, and `HEAD`).

## Exit Codes

- `0`: `PR_FETCH_OK`, `PR_DRAFT_OK`, `PR_REPLY_OK`, `PR_RESOLVE_OK`, `PR_COMMENT_OK`, `PR_IDEMPOTENT_SKIP`, `PR_ALREADY_RESOLVED`.
- `1`: `PR_INVALID_ARGS`, `PR_TARGET_MISMATCH`, `PR_NOT_RESOLVABLE`, `PR_INVALID_ANCHOR`, `PR_FILE_GUARD`, `PR_POST_WRITE_UNVERIFIED`, `PR_API_ERROR`.
- `2`: `PR_AUTH_REQUIRED`, `PR_EVENT_UNAUTHORIZED`, `PR_NOT_OPEN`, `PR_STALE_HEAD`, `PR_VERIFY_REQUIRED`, `PR_FIX_NOT_REMOTE`, `PR_DIFF_UNAVAILABLE`, `PR_KEY_COLLISION`, `PR_CONCURRENT_LOCK`, `PR_RECONCILIATION_REQUIRED`, `PR_PAGINATION_INCOMPLETE`, `PR_POST_WRITE_HEAD_MOVED`.
