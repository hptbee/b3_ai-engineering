---
name: b3-pr-reply
description: Explicit command wrapper ($b3-pr-reply, /b3-pr-reply, b3-pr-reply) to reply to selected PR comments or review threads with verified evidence via pr-feedback skill. Never edits code or resolves threads.
---

# b3-pr-reply

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, host global fallback, or this repo) and run `reply` via `{B3_HOME}/skills/engineering/pr-feedback/SKILL.md` (`references/{reply-template,github-adapter}.md` on demand). Inspect code/evidence first; include permalink/reference for general comments; support `--draft`; parent orchestrator owns external PR writes (parallel workers stay read-only/`--draft`; `PR_MUTATION_OWNER_REQUIRED`); never edit source code or auto-resolve threads.
