---
name: b3-pr-reply
description: Reply to selected PR review threads or comments with verified evidence. Never edits code or resolves threads.
---

# b3-pr-reply

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, or this repo) and execute the `reply` mode in `{B3_HOME}/skills/engineering/pr-feedback/SKILL.md` (loading `references/{reply-template,github-adapter}.md` on demand). Supports `fixed`, `already-fixed`, `disagreement`, `clarification`, `duplicate`, `blocked`, and `--draft` in concise US English; includes a reference/permalink for general comments; never edits source code or resolves threads.
