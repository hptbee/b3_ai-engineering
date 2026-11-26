---
name: b3-pr-comment
description: Explicit command wrapper ($b3-pr-comment, /b3-pr-comment, b3-pr-comment) to publish a verified B3 review result to a PR (summary, inline, both, or draft) via pr-feedback skill. Not for PR merge.
---

# b3-pr-comment

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, host global fallback, or this repo) and run `comment` via `{B3_HOME}/skills/engineering/pr-feedback/SKILL.md` (`references/{reply-template,thread-lifecycle,github-adapter}.md` on demand). Prep workers stay `SHARED_READ_ONLY`/`--draft` (`{B3_HOME}/workflows/references/dispatch-naming.md`) while Parent serializes `b3 pr comment` writes (`PR_MUTATION_OWNER_REQUIRED`); validate diff-hunk anchors, delta-revalidate on moved HEAD, post `CONFIRMED` findings only, default `COMMENT`, never auto-merge.
