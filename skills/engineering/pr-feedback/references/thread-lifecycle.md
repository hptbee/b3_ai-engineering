# PR Thread Lifecycle, Freshness & Idempotency

SCM-neutral rules governing classification, evidence-bound thread resolution, freshness/race handling, idempotency, and Research Ship governance.

## 1. Review Threads vs. General PR Comments

| Target kind | Reply behavior | Thread resolution |
| --- | --- | --- |
| `review_thread` | Direct inline thread reply | Eligible only when all §3 gates pass |
| `general_comment` | PR conversation reply including a reliable reference or permalink to the original comment | **Never** — general comments are not resolvable review threads |

## 2. Classification -> Allowed Actions Matrix

Validate every item against current PR `HEAD`, requirements, callers, and tests before classifying.

| Classification | Code change | Reply template | Eligible to resolve (`review_thread` only) |
| --- | --- | --- | --- |
| `CONFIRMED` | Fix root cause (`problem-solving` + `verification` + `b3-reviewer`) | Fixed | **Yes**, only after fix is pushed to remote PR `HEAD` and §3 evidence/remote gates pass |
| `ALREADY_FIXED` | None | Already Fixed | **Yes**, only with §3 bound evidence proving the fix on remote PR `HEAD` |
| `DUPLICATE` | Consolidated with primary root cause | Duplicate | **Yes**, only after primary root-cause fix passes §3 gates (evidence names `primary_thread_id`) |
| `OUTDATED` | None | Already Fixed or Clarification | **No** directly — reclassify to `ALREADY_FIXED` with bound evidence first, else leave open |
| `DISAGREED` | None | Disagreement | **No** — always leave open |
| `NEEDS_CLARIFICATION` | None | Clarification | **No** — always leave open |
| `BLOCKED` | None | Blocked | **No** — always leave open |

## 3. Resolution Verification & Gates (All Mandatory)

Caller-supplied `PASS` flags and commit ancestry alone are **not** sufficient to resolve a thread. A `review_thread` may be resolved only when **all** hold:
1. Separate explicit resolve authorization is granted.
2. Bound verification evidence (`schema=b3-pr-verify-evidence-v1`) matches the exact repository, PR, current `HEAD` SHA, `thread_id`, `fix_commit`, remote `thread.path`, and references a valid passing `b3-verify-v1` receipt (`status=PASS`, `exit_code=0`, `head_sha == expected_head`, relevant paths covering target/fix paths).
3. Remote PR is `OPEN`, remote `HEAD == expected_head`, `fix_commit` is a remote ancestor of `HEAD` (`identical|ahead`, `behind_by == 0`), **and** remote `fix_commit` modifies the thread's target path or declared verified `fixed_paths`.
4. Pre-write freshness recheck passes immediately before mutation; post-write remote verification confirms `isResolved == true`, target ownership, and unchanged `HEAD`.

## 4. Mutation Freshness, Race Windows & Reconciliation

- **Pre-write recheck:** Recheck remote PR `state == OPEN` and `headRefOid == expected_head` immediately before every mutation (after all paginated/diff reads).
- **Explicit outcomes:**
  - `blocked_before_write` (`mutated: false`): PR closed, stale HEAD, auth/evidence failure, key collision, or active lock.
  - `mutated_but_stale` (`mutated: true`, `PR_POST_WRITE_HEAD_MOVED`): mutation succeeded remotely, but `HEAD` moved concurrently. Preserve created IDs/recovery evidence and require remote reconciliation (`fetch --state-file`) before continuing dependent operations.
  - `mutated_unverified` (`mutated: true`, `PR_POST_WRITE_UNVERIFIED`): remote re-fetch could not verify the created object/actor/content/state. Preserve created IDs and require reconciliation.
- **Provider race honesty:** GitHub APIs do not provide server-side atomic check-HEAD-and-mutate transactions. Pre-write + post-write checks shrink the race window and detect races deterministically; they do not guarantee provider-side atomicity.

## 5. Stale Review Handling & Inline Diff Validation

- **Reuse vs delta:** Reuse an existing B3 review only when `reviewed_sha == remote_head`, scope, and evidence remain valid. If `HEAD` moved, inspect `git diff <reviewed_sha>..<current_head>` and revalidate affected findings instead of posting stale findings or running an unnecessary full review.
- **Inline diff anchors:** Validate actual diff-hunk line numbers and `RIGHT`/`LEFT` sides against the live PR diff patch — not merely changed-file membership. If a file's patch is unavailable or truncated, fail closed (`PR_DIFF_UNAVAILABLE`) rather than guessing line anchors.
- **Review Loop:** Publish only the final verified outcome when authorized — never intermediate iteration spam.

## 6. Idempotency & Retry Safety

- **Mandatory stable identity:** Every external reply/comment carries `<!-- b3-pr-key:<key>;op=<16hex> -->`, automatically derived if `--idempotency-key` is omitted. `op` hashes `(repo, pr, actor, op, target, reviewed_sha, mode, event, normalized_payload)`.
- **Anti-spoofing & collision detection:** Scan only the authenticated actor (`viewer`) on the exact target. Same `key` + same `op` -> `PR_IDEMPOTENT_SKIP`. Same `key` + different `op`/payload -> fail closed `PR_KEY_COLLISION` (never silently skip a different operation).
- **Concurrency & limits:** Atomic state-file lock prevents concurrent local retries (`PR_CONCURRENT_LOCK`). Because GitHub lacks server-side idempotency keys, this provides best-effort client-side deduplication and remote reconciliation, **not** strict server-enforced exactly-once delivery.

## 7. Research Ship Governance

Under `/b3-research-ship`:
1. Reviewer feedback on code/formatting/tests may be handled normally with full verification.
2. Never apply edits that weaken research provenance, contradict verified primary sources, or alter editorial/release claims without re-verification — escalate as `DISAGREED` or `BLOCKED`.
3. Resolving PR threads or posting `APPROVE` comments never satisfies editorial approval, product-authority sign-off, or release authorization.
