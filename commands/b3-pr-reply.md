---
name: b3-pr-reply
description: Reply to selected PR review threads or comments with verified evidence. Never edits code or resolves threads.
---

# b3-pr-reply

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, host global fallback, or this repo) and execute `reply` in `{B3_HOME}/skills/engineering/pr-feedback/SKILL.md` (`references/{reply-template,github-adapter}.md` on demand). Supports `fixed`, `already-fixed`, `disagreement`, `clarification`, `duplicate`, `blocked`, and `--draft` in concise US English; shares one `b3 pr fetch` across concurrent `SHARED_READ_ONLY` thread analyzers / `--draft` preparers (`{B3_HOME}/workflows/references/dispatch-naming.md`), while Parent serializes `b3 pr reply` writes (`PR_MUTATION_OWNER_REQUIRED`); includes a reference/permalink for general comments; never edits source code or resolves threads.
