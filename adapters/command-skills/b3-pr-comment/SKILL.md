---
name: b3-pr-comment
description: Publish a verified B3 review result to a PR ($b3-pr-comment, /b3-pr-comment) in summary, inline, both, or draft mode.
---

# b3-pr-comment

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, or this repo) and run `comment` via `{B3_HOME}/skills/engineering/pr-feedback/SKILL.md` (`references/{reply-template,thread-lifecycle,github-adapter}.md` on demand). Validate diff-hunk anchors, delta-revalidate on moved HEAD, post `CONFIRMED` findings only, default `COMMENT`, never auto-merge.
