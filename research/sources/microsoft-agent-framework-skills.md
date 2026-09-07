# Microsoft Agent Framework — Skills

## Source

https://learn.microsoft.com/en-us/agent-framework/agents/skills

## Tier

Tier 2 (official vendor docs for a framework, not Cursor/Claude/Codex host)

## Purpose

How Microsoft Agent Framework exposes agentskills.io-compatible skills via `SkillsProvider` and tool APIs.

## Architecture

SkillsProvider registers tools: `load_skill`, `read_skill_resource`, `run_skill_script`. Progressive disclosure identical to spec. Multiple sources composable into one provider.

## Important Patterns

- Spec alignment repeated (name, description constraints)
- Explicit tool surface for resource loading vs inline dumping
- Framework-level skill discovery from directories

## Skill Design

Same SKILL.md layout as agentskills.io.

## Rules / Instructions

Not covered.

## Agents

Agent Framework agents consume skills via provider — skills are not agents.

## Commands / Workflows

Programmatic, not slash commands.

## Evaluation

Not covered in doc.

## Portability

Confirms spec as cross-framework interchange format.

## Strengths

- Shows how hosts **should** expose skills as tools (load on demand)
- Reinforces reference/script separation

## Weaknesses / Trade-offs

- Another framework layer — Anthropic article warns against unnecessary frameworks
- .NET-centric implementation details

## Interesting Implementation Details

- Three provider construction patterns documented (directory, composite, etc.)

## Relevant Files

- Learn page sections on SKILL.md format and SkillsProvider

## Evidence

- Microsoft Learn page (large fetch 2026-09-07)

## Relevance to b3-ai-engineering

Secondary confirmation of portable SKILL.md + tool-based resource loading pattern.

## Initial Recommendation

OBSERVE — reinforces ADOPT on spec, not MS-specific provider code
