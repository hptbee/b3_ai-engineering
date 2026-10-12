# Adapters

Cursor is the first host. This repository’s `.cursor/` tree **is** the Cursor integration (committed, not generated).

`adapters/` documents other hosts and provides cross-platform local-install helpers. Codex skills are exposed through a local discovery link; no duplicate skill tree is committed. Runtime discovery is tracked separately from link creation.

Do **not** commit duplicate skill trees under `.agents/`, `.claude/`, or `.codex/` in this Cursor-first repo (Cursor would triple-discover the same skills).

## Host path matrix

| Host | Skills | Rules | Project context | Subagents |
| --- | --- | --- | --- | --- |
| **Cursor** | `.cursor/skills/` (canonical, committed) | `.cursor/rules/*.mdc` `@`-includes `rules/*.md` | `AGENTS.md`; commands in `.cursor/commands/` (`/autodev` included) | `.cursor/agents/` |
| **Codex** | local symlink/junction `.agents/skills` → `.cursor/skills` | `AGENTS.md` | prompt routing + delegated roles | No documented repository custom-agent file surface; role prompts preserve isolation where delegated |
| **Claude Code** | symlink `.claude/skills` → `.cursor/skills` | Claude rules / `CLAUDE.md` bridge | `CLAUDE.md` → `@AGENTS.md` | `.claude/agents/` mapped from `.cursor/agents/` |

## Per-host docs

| Adapter | File |
| --- | --- |
| Cursor | [`cursor/README.md`](cursor/README.md) |
| Codex | [`codex/README.md`](codex/README.md) |
| Claude Code | [`claude/README.md`](claude/README.md) |

## Export helper (other hosts only)

```bash
./adapters/sync-skills.sh codex     # macOS/Linux: .agents/skills → ../.cursor/skills
# Windows PowerShell:
./adapters/sync-skills.ps1 -HostName codex
./adapters/sync-skills.sh claude    # .claude/skills → ../.cursor/skills
./adapters/sync-skills.sh --dry-run all
```

There is no `cursor` target. Cursor already has the files.

On Windows the PowerShell helper creates a junction, which does not require developer-mode symlink privileges. The link is ignored and must be recreated after a fresh clone.

## Deferred

- Automated adapter CI
- Hook wrappers for review-loop gates
- Marketplace / team publishing
- Committing Codex/Claude trees (intentionally avoided: local links are installation artifacts)

See `research/decisions/decision-009-cursor-native-layout.md` (amends decision-002 location, not meaning).
