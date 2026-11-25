# PR Thread Lifecycle, Freshness & Idempotency

SCM-neutral rules governing classification, canonical verification-bound thread resolution, freshness/race handling, idempotency, and Research Ship governance.

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
| `ALREADY_FIXED` | None | Already Fixed | **Yes**, only with §3 bound canonical verification proving the fix on remote PR `HEAD` |
| `DUPLICATE` | Consolidated with primary root cause | Duplicate | **Yes**, only after primary root-cause fix passes §3 gates (`primary_thread_id` remotely resolved) |
| `OUTDATED` | None | Already Fixed or Clarification | **No** directly — reclassify to `ALREADY_FIXED` with bound verification first, else leave open |
| `DISAGREED` | None | Disagreement | **No** — always leave open |
| `NEEDS_CLARIFICATION` | None | Clarification | **No** — always leave open |
| `BLOCKED` | None | Blocked | **No** — always leave open |

## 3. Resolution Verification & Gates (All Mandatory)

Caller-supplied `PASS` flags, commit ancestry, and touching the same file are **not** semantic proof of resolution. A `review_thread` may be resolved only when **all** hold:
1. Separate explicit resolve authorization is granted.
2. Bound verification evidence (`schema=b3-pr-verify-evidence-v1`) matches exact repository, PR, current `HEAD` SHA, `thread_id`, `fix_commit`, remote `thread.path`, `resolution_basis`, `checked_command`, and substantive summary.
3. Canonical B3 verification (`b3-guard verify-check` against exact remote PR `HEAD`, expected command, required target/fix paths, and live Git tree fingerprint — rejecting duplicate/malformed receipt fields, stale fingerprints, and ancestor-only HEADs) returns `VERIFY_VALID`.
4. Remote PR is `OPEN`, remote `HEAD == expected_head`, `fix_commit` is a remote ancestor of `HEAD` (`identical|ahead`, `behind_by == 0`), **and** remote `fix_commit` modifies all verified paths.
5. Immediate pre-write freshness check passes; post-write remote verification confirms `isResolved == true`, target ownership, and unchanged `OPEN` + `HEAD`. If trustworthy verification cannot be established, leave the thread open.

## 4. Mutation Freshness, Race Windows & Explicit Reconciliation

- **Pre-write recheck:** Recheck remote PR `state == OPEN` and `headRefOid == expected_head` immediately before every mutation (after all reads).
- **Explicit outcomes:**
  - `blocked_before_write` (`mutated: false`): PR closed, stale HEAD, auth/verification failure, key collision, remote mismatch, or active lock.
  - `mutated_but_stale` (`mutated: true`, `PR_POST_WRITE_HEAD_MOVED`): mutation landed remotely, but PR state/HEAD changed concurrently.
  - `mutated_unverified` (`mutated: true`, `PR_POST_WRITE_UNVERIFIED`): post-write verification could not confirm remote object/state/content.
- **No false clear on `fetch`:** Read-only retrieval NEVER clears pending mutation state. Dependent writes stay blocked until `reconcile` checks each pending operation against live remote objects and classifies `CONFIRMED_SUCCESS`, `CONFIRMED_ABSENCE`, `STALE_MUTATION`, or `UNCERTAIN` (keeping writes blocked while `UNCERTAIN`).
- **Provider limits:** GitHub APIs do not provide server-side atomic check-HEAD-and-mutate transactions; pre/post checks shrink the race window and detect races without claiming server-side atomicity.

## 5. Stale Review Handling & Inline Diff Validation

- **Reuse vs delta:** Reuse an existing B3 review only when `reviewed_sha == remote_head`, scope, and evidence remain valid. If `HEAD` moved, inspect `git diff <reviewed_sha>..<current_head>` and delta-revalidate affected findings.
- **Strict diff hunk validation:** Parse and verify unified diff hunk line counts and completeness (preserving additions, deletions, context lines, and `LEFT`/`RIGHT` anchors). Reject malformed, truncated, or missing patches (`PR_DIFF_UNAVAILABLE`); never guess anchors.
- **Review Loop:** Publish only the final verified outcome when authorized — never intermediate iteration spam.

## 6. Mandatory Canonical State, Locking & Revalidated Idempotency

- **Canonical state identity:** Every external mutation automatically uses one repository-and-PR-scoped state file (omitted or alternate `--state-file` overrides are disallowed). Read-only `fetch` and `--draft` remain lightweight without creating state or lock files.
- **PID + host liveness lock:** Never reclaim locks based solely on wall-clock age. Only reclaim a same-host lock whose recorded PID is confirmed dead (`ESRCH`); fail closed on active, cross-host, or unverifiable locks.
- **Revalidated idempotency:** Every external reply/comment carries an actor-scoped `<!-- b3-pr-key:<key>;op=<16hex> -->` identity (auto-derived if omitted). Before returning `PR_IDEMPOTENT_SKIP`, revalidate the actual remote object's content, target, actor, event/state (rejecting dismissed reviews or edited comments as `PR_REMOTE_STATE_MISMATCH`), and commit SHA. Best-effort client deduplication only — not server-enforced exactly-once delivery.

## 7. Research Ship Governance

Under `/b3-research-ship`:
1. Reviewer feedback on code/formatting/tests may be handled normally with full canonical verification.
2. Never apply edits weakening research provenance, contradicting verified primary sources, or altering editorial/release claims without re-verification (`DISAGREED` / `BLOCKED`).
3. Thread resolution or `APPROVE` comments never satisfies editorial approval, product-authority sign-off, or release authorization.
