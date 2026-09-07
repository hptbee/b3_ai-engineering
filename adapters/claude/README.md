# Claude Code adapter

**Status:** path matrix + CLAUDE.md bridge pattern documented. No `.claude/` tree committed yet.

## Portable core → Claude Code

| Core | Claude mapping |
| --- | --- |
| `AGENTS.md` | Source of truth; bridge from `CLAUDE.md` via `@AGENTS.md` import |
| `rules/*.md` | Claude rules / project instructions — same meaning |
| `skills/<name>/SKILL.md` | Symlink `skills/` → `.claude/skills/` via [`../sync-skills.sh`](../sync-skills.sh) |
| `commands/` | Claude commands when command layer exists |
| `agents/` | `.claude/agents/` subagents when roles exist |

## CLAUDE.md bridge

Claude Code often expects root `CLAUDE.md`. **Do not fork** the handbook — generate a pointer file:

```markdown
# Project instructions

Follow @AGENTS.md for operating context, precedence, and review standards.

Skills: `.claude/skills/` (symlinked from portable `skills/`).
Rules: see portable `rules/` — map to Claude rules without rewriting policy.
```

Optional: commit `CLAUDE.md` in repo after user approval, or document generation in this adapter only.

## Plugin / marketplace namespacing

Third-party plugins may use namespaced skill and subagent names (e.g. `plugin:skill-name`). Portable core skills use simple `name:` fields — adapter docs map host dispatch strings when integrating OSS plugins (e.g. Trail of Bits differential-review).

Do **not** copy namespaced subagent names into portable `skills/`.

## allowed-tools frontmatter

Some Claude/OSS skills declare `allowed-tools`. Portable foundation skills omit this — optional generated overlay in `.claude/skills/<name>/` if user wants tool restrictions.

## Hooks (optional layer)

Claude plugins support SessionStart/hook enforcement (see Superpowers, dev-loop in research). Hooks are **not** portable — document optional hook wrappers here that invoke review or verification procedures.

Portable core must remain usable without hooks.

## Symlink

```bash
./adapters/sync-skills.sh claude
# creates .claude/skills → ../skills
```

## Thin by design

Permission prompts, MCP server lists, and Claude hook JSON belong here. Engineering method stays in portable core.

## References

- [`../README.md`](../README.md)
- `research/sources/claude-code-skills-plugins.md`
- `research/decisions/decision-002-portability.md`
