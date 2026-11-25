---
name: b3-pr-resolve
description: Explicit command wrapper ($b3-pr-resolve, /b3-pr-resolve, b3-pr-resolve) to validate, fix, verify, reply, and resolve eligible PR threads via pr-feedback skill. Not for PR merge.
---

# b3-pr-resolve

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, or this repo) and run `resolve` via `{B3_HOME}/skills/engineering/pr-feedback/SKILL.md` (`references/{thread-lifecycle,reply-template,github-adapter}.md` on demand). Require bound verification evidence (`b3-verify-v1` receipt + fix relevance) before resolving eligible `review_thread` items; never resolve general comments, disputed/unclear/blocked items, or auto-merge.
