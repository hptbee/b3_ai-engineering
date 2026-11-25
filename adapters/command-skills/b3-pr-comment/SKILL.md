---
name: b3-pr-comment
description: Publish a verified B3 review result to a PR ($b3-pr-comment, /b3-pr-comment) in summary, inline, both, or draft mode.
---

# b3-pr-comment

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, or this repo) and run the `comment` mode in `{B3_HOME}/skills/engineering/pr-feedback/SKILL.md` (load `references/{reply-template,thread-lifecycle,github-adapter}.md` on demand):
- Support `summary`, `inline`, `both` (no inline body duplication in summary), and `--draft`.
- Reuse an existing B3 review only when `HEAD` SHA, scope, and evidence remain valid; if `HEAD` moved, delta-revalidate affected findings first. Post ONLY `CONFIRMED` findings (`CRITICAL|HIGH|MEDIUM|LOW`).
- Default `--event COMMENT`; require `--authorize-write` (and matching `--authorize-review-event` for `APPROVE`/`REQUEST_CHANGES`). Never auto-merge.
