---
name: b3-pr-comment
description: Publish an existing verified B3 review result to a PR (summary, inline, both, or draft) with SHA freshness checks.
---

# b3-pr-comment

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, or this repo) and run the `comment` flow in `{B3_HOME}/skills/engineering/pr-feedback/SKILL.md` (+ `references/reply-template.md`, `references/thread-lifecycle.md`, `references/github-adapter.md` on demand):
- **Modes:** `summary` (one consolidated comment), `inline` (valid PR diff locations only), `both` (compact summary without duplicating inline bodies), or `--draft` (preview only).
- **Freshness & signal:** reuse an existing B3 review only when target `HEAD` SHA, scope, and evidence remain valid; if `HEAD` moved, delta-revalidate affected findings first (never silently post stale findings or run an unnecessary full review). Post ONLY `CONFIRMED` findings using `CRITICAL | HIGH | MEDIUM | LOW`.
- **Authorization:** default `--event COMMENT`; require `--authorize-write` for posting and matching `--authorize-review-event` for `APPROVE`/`REQUEST_CHANGES`. Never auto-merge.
