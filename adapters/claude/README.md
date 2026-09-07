# Claude Code adapter

**Status:** intended mapping only. No `.claude/` tree is generated yet.

## Portable core → Claude Code

| Core | Claude-oriented mapping (planned) |
| --- | --- |
| `AGENTS.md` | May be mirrored or pointed to from `CLAUDE.md` without forking policy |
| `rules/` | Map to Claude rules / instructions; same meaning |
| `skills/*/SKILL.md` | Map to Claude Code skills (`SKILL.md` layout is already aligned) |
| `commands/` | Map to Claude commands when the command layer exists |
| `agents/` | Map to Claude subagents when roles exist |

If Claude requires `CLAUDE.md` at a repo root, generate or copy **pointers** from this adapter, not a second full handbook.

## Thin by design

Claude hooks, permission prompts, and MCP server lists belong here. Engineering method stays portable.
