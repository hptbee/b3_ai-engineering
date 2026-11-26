---
name: b3-pr-resolve
description: Handle PR review feedback end-to-end: validate, fix confirmed root causes, verify, reply, and resolve eligible threads.
---

# b3-pr-resolve

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, host global fallback, or this repo) and execute the `resolve` mode in `{B3_HOME}/skills/engineering/pr-feedback/SKILL.md` (loading `references/{thread-lifecycle,reply-template,github-adapter}.md` on demand). Supports all unresolved threads, selected threads, and `--draft`; parent orchestrator owns external PR mutations (parallel workers stay read-only/`--draft`; `PR_MUTATION_OWNER_REQUIRED`); requires exact-commit canonical `b3-guard verify-check` + fix relevance before resolving eligible `review_thread` items; never auto-merges.
