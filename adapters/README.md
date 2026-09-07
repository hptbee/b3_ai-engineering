# Adapters

Cursor is the first host. This repository’s `.cursor/` tree **is** the Cursor integration (committed, not generated).

`adapters/` documents other hosts and provides an export helper. Mappings for Codex and Claude are **intended**; they have not been exercised in this repository.

Do **not** commit duplicate skill trees under `.agents/`, `.claude/`, or `.codex/` in this Cursor-first repo (Cursor would triple-discover the same skills).

## Host path matrix

| Host | Skills | Rules | Project context | Subagents |
| --- | --- | --- | --- | --- |
| **Cursor** | `.cursor/skills/` (canonical, committed) | `.cursor/rules/*.mdc` `@`-includes `rules/*.md` | `AGENTS.md` | `.cursor/agents/` |
| **Codex** | symlink `.agents/skills` → `.cursor/skills` | Link from `AGENTS.md` | `AGENTS.md` | Map from `.cursor/agents/` |
| **Claude Code** | symlink `.claude/skills` → `.cursor/skills` | Claude rules / `CLAUDE.md` bridge | `CLAUDE.md` → `@AGENTS.md` | `.claude/agents/` mapped from `.cursor/agents/` |

## Per-host docs

| Adapter | File |
| --- | --- |
| Cursor | [`cursor/README.md`](cursor/README.md) |
| Codex | [`codex/README.md`](codex/README.md) |
| Claude Code | [`claude/README.md`](claude/README.md) |

## Export helper (other hosts only)

```bash
./adapters/sync-skills.sh codex     # .agents/skills → ../.cursor/skills
./adapters/sync-skills.sh claude    # .claude/skills → ../.cursor/skills
./adapters/sync-skills.sh --dry-run all
```

There is no `cursor` target. Cursor already has the files.

On Windows, junctions are the local equivalent of `ln -s` if bash is missing:

```text
cmd /c mklink /J .agents\skills .cursor\skills
```

## Deferred

- Automated adapter CI
- Hook wrappers for review-loop gates
- Marketplace / team publishing
- Committing Codex/Claude trees

See `research/decisions/decision-009-cursor-native-layout.md` (amends decision-002 location, not meaning).
