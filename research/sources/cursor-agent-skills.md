# Cursor Agent Skills (official docs)

## Source

https://cursor.com/docs/skills

## Tier

Tier 1

## Purpose

Define how Cursor discovers, scopes, and invokes Agent Skills using the open SKILL.md standard.

## Architecture

- Skills are folders with `SKILL.md` plus optional `scripts/`, `references/`, `assets/`.
- At startup Cursor loads skill **metadata** (name + description); full body loads on activation.
- Agent decides relevance from description; user can invoke via `/skill-name`.
- Built-in skills (`/create-skill`, `/migrate-to-skills`, `/review`, subagent creators) ship with the product.

## Important Patterns

- Progressive disclosure (metadata → body → bundled files)
- `paths` glob scoping (or implicit scoping via nested `.cursor/skills/` placement)
- `disable-model-invocation: true` for human-only slash-command behavior
- Cross-loader compatibility: `.agents/skills/`, `.cursor/skills/`, `.claude/skills/`, `.codex/skills/`
- Rules/commands migration path to skills (`/migrate-to-skills`)

## Skill Design

Required frontmatter: `name` (matches folder), `description`. Optional: `paths`, `disable-model-invocation`, `icon`, `color`, `metadata`. Recommended layout mirrors agentskills.io spec.

## Rules / Instructions

Skills are **not** standing rules. Persistent constraints remain in `.cursor/rules` (`.mdc`) or `AGENTS.md`. Cursor explicitly distinguishes always-on rules from on-demand skills.

## Agents

Built-in subagents (Explore, Bash, Browser) handle context-heavy ops; custom subagents live in `.cursor/agents/`. Docs map **subagents vs skills**: isolation/parallelism → subagent; single-purpose repeatable procedure → skill.

## Commands / Workflows

Legacy `.cursor/commands/` still load but skills are the recommended shape. `/loop` runs prompts/skills on interval. Custom Modes can pin a skill for a whole session.

## Evaluation

No first-party eval harness documented on this page. Built-in `/create-skill` assists authoring.

## Portability

Skills follow Agent Skills open standard; Cursor adds extensions (`paths`, `icon`, `color`, nested discovery). Core SKILL.md portable; extensions belong in adapters.

## Strengths

- Clear separation of rules vs skills vs subagents
- Explicit progressive loading model
- Practical scoping via paths and nested directories
- Loads Claude/Codex skill paths for cross-tool repos

## Weaknesses / Trade-offs

- Multiple discovery roots (`.cursor/`, `.agents/`, `.claude/`, `.codex/`) increase confusion
- Cloud/self-hosted caveats: personal `~/.cursor/skills/` sync rules differ from repo skills
- Host-specific frontmatter extensions risk forked cores if copied verbatim

## Interesting Implementation Details

- Nested `.cursor/skills/` under monorepo packages auto-scopes to subtree (similar to `paths`)
- `globs` legacy alias still accepted for `paths`
- Team marketplace publishing separate from personal skill sync

## Relevant Files

- Official doc sections: Skill directories, SKILL.md format, Scoping, Custom Modes, Migration

## Evidence

- https://cursor.com/docs/skills (fetched 2026-09-07): discovery paths, frontmatter table, progressive loading, subagent cross-reference

## Relevance to b3-ai-engineering

Validates portable `skills/*/SKILL.md` core with thin Cursor adapter for paths, nested discovery, and `disable-model-invocation` mapping.

## Initial Recommendation

ADAPT — adopt open SKILL.md layout; map Cursor-only fields in `adapters/cursor/`.
