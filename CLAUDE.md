# Project instructions

Follow @AGENTS.md for operating context, precedence, canonical paths, and review standards.

- Canonical core: `rules/`, `skills/`, `commands/`, `agents/`, `workflows/`, `review-loop/`.
- Local Claude Code activation (gitignored): run `./adapters/sync-skills.sh claude` or `.\adapters\sync-skills.ps1 -HostName claude` to expose `.claude/skills/<name>` (core skills + `adapters/command-skills/`) and `.claude/agents` → `agents/`.
