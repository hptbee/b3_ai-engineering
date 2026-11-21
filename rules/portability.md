---
type: rule
strength: hard
scope: global
source: synthesized
authority: high
---

# Portability

Hard rule: portable **meaning** (`AGENTS.md`, `docs/`, `rules/`, `skills/`, `commands/`, `agents/`, `workflows/`, `review-loop/`, `knowledge/`, `research/`) must not be rewritten per host.

Hard rule: canonical skills, commands, agents, and rules live in host-neutral root directories (`skills/`, `commands/`, `agents/`, `rules/`) so Cursor, Codex, Claude Code, and Antigravity consume the same single source of truth (decision-013, superseding decision-009).

Hard rule: host-only metadata and activation wrappers (`.cursor/rules/*.mdc`, `CLAUDE.md`, `.agents/skills.json`, hooks, MCP, local discovery links, plugin generators) belong in thin host entrypoints or `adapters/`. Adapters may map, link, or generate; they may not fork meaning.

Strong guideline: prefer Markdown, `SKILL.md`, YAML frontmatter, and plain shell/Node/Python scripts.

Strong guideline: if a skill cannot be followed without a specific host feature, the skill is not ready — extract the portable method, then adapt.
