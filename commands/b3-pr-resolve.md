---
name: b3-pr-resolve
description: Handle PR review feedback end-to-end: validate, fix confirmed root causes, verify, reply, and resolve eligible threads.
---

# b3-pr-resolve

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, host global fallback, or this repo) and execute `resolve` in `{B3_HOME}/skills/engineering/pr-feedback/SKILL.md` (`references/{thread-lifecycle,reply-template,github-adapter}.md` on demand). Supports all unresolved threads, selected threads, and `--draft`; shares one `b3 pr fetch` across concurrent `SHARED_READ_ONLY` thread analyzers and disjoint fixers (`{B3_HOME}/workflows/references/dispatch-naming.md`), while Parent serializes `b3 pr {reply,resolve}` mutations (`PR_MUTATION_OWNER_REQUIRED`); requires exact-commit `b3 guard verify-check` + fix relevance before resolving `review_thread` items; never auto-merges.
