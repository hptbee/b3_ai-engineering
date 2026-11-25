# PR Thread Lifecycle, Freshness & Idempotency

SCM-neutral rules governing classification, review-thread resolution, stale-review revalidation, retry idempotency, and Research Ship governance.

## 1. Review Threads vs. General PR Comments

| Target kind | Description | Reply supported | Thread resolution supported |
| --- | --- | --- | --- |
| `review_thread` | Diff-anchored inline review thread with thread ID and `isResolved` state | Yes (thread reply) | Yes (only when all resolution gates pass) |
| `general_comment` | Top-level PR conversation comment (issue comment) | Yes (PR conversation reply quoting/referencing target) | **No** — never call thread-resolve APIs on general comments |

## 2. Classification -> Allowed Actions Matrix

Every fetched item MUST be validated against current PR `HEAD`, requirements, callers, and tests before classification.

| Classification | Code change | Reply template | Eligible to resolve (`review_thread` only) |
| --- | --- | --- | --- |
| `CONFIRMED` | Fix root cause (`problem-solving` + `verification` + `b3-reviewer`) | Fixed | **Yes**, ONLY after fix is committed, pushed to remote PR `HEAD`, verified `PASS`, and remotely confirmed |
| `ALREADY_FIXED` | None | Already Fixed | **Yes**, ONLY after verifying the fix commit or code is present on remote PR `HEAD` and verified |
| `DUPLICATE` | Consolidated with primary root cause | Duplicate | **Yes**, ONLY after the primary root-cause fix is verified `PASS` and confirmed on remote PR `HEAD` |
| `OUTDATED` | None | Already Fixed or Clarification | **No** directly — reclassify to `ALREADY_FIXED` with concrete code/commit evidence first, otherwise leave open |
| `DISAGREED` | None | Disagreement | **No** — always leave open for reviewer response |
| `NEEDS_CLARIFICATION` | None | Clarification | **No** — always leave open for reviewer answer |
| `BLOCKED` | None | Blocked | **No** — always leave open until blocker is cleared |

## 3. Resolution Gates (All Mandatory)

A `review_thread` may be resolved ONLY when **all** of the following hold:
1. Separate explicit resolve authorization is granted (independent of write/reply and push authorizations).
2. Remote PR state is `OPEN` and remote `HEAD` equals `expected_head`.
3. Target is verified to be a `review_thread` belonging to `<repo>#<pr>` (not a `general_comment` or another PR's thread).
4. Verification status is strictly `PASS` (`FAIL`, `INCOMPLETE`, or missing evidence blocks resolution).
5. The fix commit is proven reachable in the remote PR `HEAD` ancestry (never resolve based solely on a local unpushed commit).
6. Post-write remote verification confirms `isResolved == true` **and** remote `HEAD` still equals `expected_head`. If `HEAD` moved concurrently, report `PR_POST_WRITE_HEAD_MOVED` and stop for revalidation.

## 4. Stale Review Handling (`b3-pr-comment` & `b3-review --post`)

- **Valid reuse:** Reuse an existing B3 review result when its `reviewed_sha == remote_head`, target scope matches, and verification evidence is intact.
- **Changed PR HEAD:** Never silently post findings from an older `HEAD`, and never blindly re-run an expensive full review by default. Inspect the delta (`git diff <reviewed_sha>..<current_head>`) and revalidate only affected files/findings:
  - Drop findings resolved by later commits.
  - Update line numbers/evidence for findings still present on `current_head`.
  - Escalate to targeted re-review only if the delta introduced new unreviewed risk.
- **No spam in Review Loop:** `/b3-review-loop` publishes only the final verified outcome when explicitly authorized — never per-iteration intermediate findings.

## 5. Idempotency & Partial-Failure Recovery

- **Authoritative ledger:** Remote SCM state (authenticated actor's own comments/reviews containing `<!-- b3-pr-key:<key> -->` on the exact target, plus `isResolved`) is the source of truth.
- **Anti-spoofing:** Ignore markers authored by any account other than the authenticated actor (`viewer`), and scope scans strictly to the target thread or PR.
- **Secondary audit file (optional):** When callers pass `--state-file` (recommended path `.b3/pr-feedback/<repo-pr>.state`), record local outcomes for audit/resume without letting stale local state override remote reality.
- **Retry behavior:** If reply succeeded and resolve failed (e.g., transient network error), retrying skips the duplicate reply (`PR_IDEMPOTENT_SKIP`) and executes only the remaining resolve step.

## 6. Research Ship Governance Enforcement

When invoked inside `/b3-research-ship`:
1. Reviewer feedback on code/formatting/tests may be handled normally, subject to full verification.
2. Reviewer suggestions that alter research provenance, contradict verified primary sources, or weaken editorial/release claims MUST NOT be blindly applied — re-verify against primary sources or classify as `DISAGREED` / `BLOCKED` for human decision.
3. Resolving PR threads or posting `b3-pr-comment --event APPROVE` NEVER satisfies Research Ship editorial approval, product-authority sign-off, or release authorization gates.
