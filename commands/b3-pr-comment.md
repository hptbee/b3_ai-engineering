---
name: b3-pr-comment
description: Publish an existing verified B3 review result to a PR (summary, inline, both, or draft) with SHA freshness checks.
---

# b3-pr-comment

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, or this repo) and execute the `comment` mode in `{B3_HOME}/skills/engineering/pr-feedback/SKILL.md` (loading `references/{reply-template,thread-lifecycle,github-adapter}.md` on demand). Supports `summary`, `inline` (validated diff-hunk anchors), `both`, and `--draft`; parent orchestrator owns external PR writes (parallel workers stay read-only/`--draft`); reuses valid reviews or delta-revalidates on moved HEAD; defaults to `COMMENT` and posts `CONFIRMED` findings only.
