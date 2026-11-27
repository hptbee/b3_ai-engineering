---
name: b3-pr-resolve
description: "Validate, fix, verify, reply, and resolve eligible PR threads via pr-feedback ($b3-pr-resolve, /b3-pr-resolve). Not for PR merge."
---

# b3-pr-resolve

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, host global fallback, or this repo) and run `resolve` via `{B3_HOME}/skills/engineering/pr-feedback/SKILL.md` (`references/{thread-lifecycle,reply-template,github-adapter}.md` on demand). Share one `b3 pr fetch` across concurrent `SHARED_READ_ONLY` analyzers and disjoint fixers (`{B3_HOME}/workflows/references/dispatch-naming.md`), while Parent serializes `b3 pr {reply,resolve}` mutations (`PR_MUTATION_OWNER_REQUIRED`); require `b3 guard verify-check` + fix relevance before resolving eligible `review_thread` items; never resolve general comments, disputed/unclear/blocked items, or auto-merge.
