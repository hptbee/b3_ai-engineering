# Cursor adapter

**Status:** intended mapping only. This folder is not a Cursor plugin and does not yet contain `.cursor/` manifests.

## Portable core → Cursor

| Core | Cursor-oriented mapping (planned) |
| --- | --- |
| `AGENTS.md` | Usable as-is where Cursor reads `AGENTS.md` |
| `rules/` | Map to Cursor rules / user rules without rewriting meaning |
| `skills/*/SKILL.md` | Map to Cursor skills discovery (`SKILL.md` + frontmatter) |
| `commands/` | Map to Cursor commands when the command layer exists |
| `agents/` | Map to Cursor subagents when roles exist |

Keep generated or Cursor-only files in this folder (or a documented output path). Do not edit core skills to mention Cursor features.

## Thin by design

Cursor-specific UI, hooks, or MCP wiring belongs here. Verification, review, and engineering method stay in `rules/` and `skills/`.
