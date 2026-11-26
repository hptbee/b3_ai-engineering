---
name: b3-pr-comment
description: Explicit command wrapper ($b3-pr-comment, /b3-pr-comment, b3-pr-comment) to publish a verified B3 review result to a PR (summary, inline, both, or draft) via pr-feedback skill. Not for PR merge.
---

# b3-pr-comment

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, host global fallback, or this repo) and run `comment` via `{B3_HOME}/skills/engineering/pr-feedback/SKILL.md` (`references/{reply-template,thread-lifecycle,github-adapter}.md` on demand). Parent orchestrator owns external PR writes (parallel workers stay read-only/`--draft`; `PR_MUTATION_OWNER_REQUIRED`); validate diff-hunk anchors, delta-revalidate on moved HEAD, post `CONFIRMED` findings only, default `COMMENT`, never auto-merge.
