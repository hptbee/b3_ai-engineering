---
name: b3-pr-reply
description: "Reply to selected PR comments or review threads with verified evidence via pr-feedback ($b3-pr-reply, /b3-pr-reply). No code edits or resolve."
---

# b3-pr-reply

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, host global fallback, or this repo) and run `reply` via `{B3_HOME}/skills/engineering/pr-feedback/SKILL.md` (`references/{reply-template,github-adapter}.md` on demand). Share one `b3 pr fetch` across concurrent `SHARED_READ_ONLY` thread analyzers / `--draft` preparers (`{B3_HOME}/workflows/references/dispatch-naming.md`), while Parent serializes `b3 pr reply` writes (`PR_MUTATION_OWNER_REQUIRED`); include permalink/reference for general comments; never edit source code or auto-resolve threads.
