# Cursor rules → skills migration (community)

## Source

https://startdebugging.net/2026/08/migrate-cursor-rules-to-skills-subagents-and-plugins/

## Tier

Tier 3

## Purpose

Practitioner checklist for splitting legacy `.cursorrules` / `.mdc` into AGENTS.md, rules, skills, subagents, plugins (Cursor 3.11 era).

## Architecture

Four destinations:
- AGENTS.md — stable project facts
- Rules — always-apply or glob-scoped constraints
- Skills — dynamic procedures (from Apply Intelligently rules + slash commands)
- Subagents — isolated multi-step roles

Documents `/migrate-to-skills` scope: converts dynamic rules + commands to skills with `disable-model-invocation` for former commands.

## Important Patterns

- Token cost motivation for migration
- Load locations table for skills/subagents across `.cursor/`, `.agents/`, `.claude/`, `.codex/`
- Team vs Project vs User precedence echoed from docs

## Skill Design

Reinforces official migration path.

## Rules / Instructions

Explicit about what **not** to migrate (always-apply, glob rules).

## Agents

Subagent paths documented alongside skills.

## Commands / Workflows

Plugin bundling as distribution unit.

## Evaluation

Anecdotal ("hour for mid-sized repo") — not measured study.

## Portability

Conceptual sorting portable; Cursor version-specific.

## Strengths

- Actionable decision tree for authors
- Links official Cursor docs as primary evidence

## Weaknesses / Trade-offs

- Third-party blog — verify against current Cursor docs
- May lag product changes

## Interesting Implementation Details

- Cursor 2.4 `/migrate-to-skills` vs 3.11 plugins narrative

## Relevant Files

- Blog checklist sections

## Evidence

- Web search fetch (2026-09-07); cross-checked with cursor.com/docs/skills migration section

## Relevance to b3-ai-engineering

Supports taxonomy: rules vs skills vs agents vs AGENTS.md — aligns with b3 architecture.

## Initial Recommendation

OBSERVE — useful author guide, not primary evidence
