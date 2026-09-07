# Claude Code adapter

**Status:** intended mapping only. No `.claude/` tree is committed and this mapping has not been verified in this repository.

## This repo → Claude Code

| Core | Claude mapping |
| --- | --- |
| `AGENTS.md` | Source of truth; bridge from `CLAUDE.md` via `@AGENTS.md` |
| `rules/*.md` | Claude rules / project instructions — same meaning |
| `.cursor/skills/` | Symlink → `.claude/skills/` via [`../sync-skills.sh`](../sync-skills.sh) |
| `.cursor/commands/` | Claude commands when command layer exists |
| `.cursor/agents/` | Map to `.claude/agents/` when roles exist |

Review-loop roles: `reviewer` (no edits), `fixer` (no PASS). Optional `model:` only in the host overlay (`review-loop/models.md`). Orchestrator remains the parent conversation.

## CLAUDE.md bridge

Claude Code often expects root `CLAUDE.md`. **Do not fork** the handbook — generate a pointer file:

```markdown
# Project instructions

Follow @AGENTS.md for operating context, precedence, and review standards.

Skills: `.claude/skills/` (symlinked from `.cursor/skills`).
Rules: see portable `rules/` — map to Claude rules without rewriting policy.
```

Optional: commit `CLAUDE.md` after user approval. Do not add it in this Cursor-first repo until Claude is actually used.

## Plugin / marketplace namespacing

Portable core skills use simple `name:` fields. Do **not** copy namespaced plugin subagent names into `.cursor/skills/`.

## allowed-tools frontmatter

Foundation skills omit `allowed-tools`. Optional overlay in `.claude/skills/<name>/` if tool restrictions are wanted.

## Hooks (optional)

Hooks are **not** portable. Optional Claude hook wrappers may invoke review or verification procedures. The core must remain usable without hooks.

## Symlink

```bash
./adapters/sync-skills.sh claude
# creates .claude/skills → ../.cursor/skills
```

## References

- [`../README.md`](../README.md)
- `research/sources/claude-code-skills-plugins.md`
- `research/decisions/decision-009-cursor-native-layout.md`
