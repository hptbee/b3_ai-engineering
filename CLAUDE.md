# Project instructions

Follow @AGENTS.md for operating context, precedence, canonical paths, and review standards.

- Canonical core: `rules/`, `skills/`, `commands/`, `agents/`, `workflows/`, `review-loop/`.
- Local Claude Code activation (gitignored): run `b3 sync --host claude` to expose `.claude/skills/<name>` (core skills + `adapters/command-skills/`) and `.claude/agents` → `agents/`.
