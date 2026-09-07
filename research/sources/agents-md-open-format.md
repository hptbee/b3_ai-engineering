# AGENTS.md Open Format

## Source

https://agents.md/

## Tier

Tier 1

## Purpose

Cross-agent convention for always-on repository guidance (build, test, conventions).

## Architecture

Plain markdown at repo root (and nested dirs). Closest file to edited code wins; **explicit user chat overrides everything**. Stewarded by Agentic AI Foundation (Linux Foundation) per site (2026).

## Important Patterns

- Complements README (humans) vs AGENTS.md (agents)
- Nested AGENTS.md in monorepos (OpenAI repo cited: 88 files)
- No required schema — freeform sections
- Ecosystem compatibility table (Codex, Copilot, Cursor, Jules, etc.)

## Skill Design

Not applicable — AGENTS.md is not a skill.

## Rules / Instructions

Always-on instructions; keep concise. Typical sections: dev environment tips, testing, PR guidelines, security.

## Agents

Format intended for any coding agent reading the repo.

## Commands / Workflows

Agents may auto-run listed test commands if documented.

## Evaluation

No eval framework.

## Portability

**High** for content. Precedence rules vary slightly by host (Codex concatenates chain; Cursor merges nested; Claude uses CLAUDE.md instead unless bridged).

## Strengths

- Simple, tool-agnostic
- Wide adoption (>60k repos claimed)
- Explicit conflict rule (proximity + user override)

## Weaknesses / Trade-offs

- No metadata → hard to classify strength/scope programmatically
- Risk of AGENTS.md bloat (everything dumped always-on)
- Overlap with skills/rules without clear author guidance on site alone

## Interesting Implementation Details

- Migration tip: symlink `AGENTS.md` ↔ `CLAUDE.md`
- Aider/Gemini config examples for pointing at AGENTS.md

## Relevant Files

- Example AGENTS.md block on homepage

## Evidence

- https://agents.md/ (fetched 2026-09-07)

## Relevance to b3-ai-engineering

Validates root `AGENTS.md` as portable entry point; detailed taxonomy stays in `docs/` not inlined into AGENTS.md.

## Initial Recommendation

ADOPT (format and role); ADAPT (keep AGENTS.md short — link to docs/skills/rules)
