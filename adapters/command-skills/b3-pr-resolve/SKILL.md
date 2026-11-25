---
name: b3-pr-resolve
description: Handle PR review feedback end-to-end ($b3-pr-resolve, /b3-pr-resolve): validate, fix, verify, reply, and resolve eligible threads. Not for PR merge.
---

# b3-pr-resolve

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, or this repo) and run `resolve` via `{B3_HOME}/skills/engineering/pr-feedback/SKILL.md` (`references/{thread-lifecycle,reply-template,github-adapter}.md` on demand). Require bound verification evidence (`b3-verify-v1` receipt + fix relevance) before resolving eligible `review_thread` items; never resolve general comments, disputed/unclear/blocked items, or auto-merge.
