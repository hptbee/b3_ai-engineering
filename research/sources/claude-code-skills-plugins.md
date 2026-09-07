# Claude Code Skills and Plugins (official docs)

## Source

- https://code.claude.com/docs/en/skills
- https://code.claude.com/docs/en/agent-sdk/plugins

## Tier

Tier 1

## Purpose

Anthropic's native skill system and plugin packaging for Claude Code and Agent SDK.

## Architecture

Skills: `.claude/skills/<name>/SKILL.md` (+ scripts/references/assets). Plugins bundle skills, agents, hooks, MCP via `.claude-plugin/plugin.json` (optional — auto-discovery supported). Commands merged into skills; `/plugin-name:skill-name` namespacing.

## Important Patterns

- Agent Skills open standard + Claude extensions (invocation control, subagent execution, dynamic context)
- Progressive disclosure identical to agentskills.io (metadata → body → resources)
- Plugin marketplace distribution (`anthropics/skills`)
- Legacy `commands/` still works but skills recommended

## Skill Design

Frontmatter drives triggering; body is procedure. Supporting files referenced from SKILL.md. `allowed-tools` in frontmatter is Claude Code CLI-only (not SDK).

## Rules / Instructions

Project memory in `CLAUDE.md` (always-on). Does **not** natively read `AGENTS.md` — bridge via `@AGENTS.md` import or symlink.

## Agents

Plugin `agents/` directory for custom subagents. Skills can trigger subagent execution (Claude extension).

## Commands / Workflows

Slash commands = skills with invocation control. Hooks in `hooks/hooks.json` for lifecycle events.

## Evaluation

Official `skill-creator` skill in `anthropics/skills` includes eval/benchmark workflow (see separate source record).

## Portability

SKILL.md core portable. CLAUDE.md, hooks, plugin manifest, `@import` syntax — adapter concerns.

## Strengths

- Mature plugin marketplace model
- Clear merge of commands → skills
- Namespacing prevents collisions in multi-plugin repos

## Weaknesses / Trade-offs

- CLAUDE.md vs AGENTS.md split hurts cross-tool repos without bridging
- Extension fields (`allowed-tools`, subagent hooks) tempt non-portable skills
- Large official skill-creator skill (~33k chars) shows eval complexity cost

## Interesting Implementation Details

- SDK `skills` option on `query()` controls enabled skill set
- Skills discovered in parent directories up to repo root

## Relevant Files

- Doc: plugin directory layout (`skills/`, `agents/`, `hooks/`, `.mcp.json`)
- anthropics/skills repo structure

## Evidence

- https://code.claude.com/docs/en/skills (partial fetch 2026-09-07)
- https://code.claude.com/docs/en/agent-sdk/plugins (fetched 2026-09-07)
- Raw `anthropics/skills` README (2026-09-07)

## Relevance to b3-ai-engineering

Confirms SKILL.md-first portable core; Claude adapter handles CLAUDE.md bridge, plugin namespacing, hooks.

## Initial Recommendation

ADAPT
