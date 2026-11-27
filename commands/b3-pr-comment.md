---
name: b3-pr-comment
description: Publish an existing verified B3 review result to a PR (summary, inline, both, or draft) with SHA freshness checks.
---

# b3-pr-comment

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, host global fallback, or this repo) and execute `comment` in `{B3_HOME}/skills/engineering/pr-feedback/SKILL.md` (`references/{reply-template,thread-lifecycle,github-adapter}.md` on demand). Supports `summary`, `inline` (validated diff-hunk anchors), `both`, and `--draft`; parallel `SHARED_READ_ONLY` review/prep workers (`{B3_HOME}/workflows/references/dispatch-naming.md`) return `--draft` payloads while Parent serializes `b3 pr comment` writes (`PR_MUTATION_OWNER_REQUIRED`); reuses valid reviews or delta-revalidates on moved HEAD; defaults to `COMMENT` and posts `CONFIRMED` findings only.
