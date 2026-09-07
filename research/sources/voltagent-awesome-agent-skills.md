# VoltAgent Awesome Agent Skills (curated list)

## Source

https://github.com/VoltAgent/awesome-agent-skills

## Tier

Tier 3

## Purpose

Curated index of 1000+ skills from official teams and community; maps tool-specific install paths.

## Architecture

README catalog organized by authoring org (Anthropic, Vercel, Trail of Bits, etc.) with links to officialskills.sh entries. Includes **Skills Paths table** for Antigravity, Claude, Codex, Cursor, Gemini, Copilot, Windsurf.

## Important Patterns

- Cross-tool path matrix (`.cursor/skills/`, `.agents/skills/`, `.claude/skills/`, etc.)
- Curation claim: "hand-picked, not AI-slop generated" (community normative statement, not verified here)
- Ecosystem discovery hub — not a single coherent system

## Skill Design

Varies per listed skill — index only.

## Rules / Instructions

N/A

## Agents

N/A

## Commands / Workflows

N/A

## Evaluation

No unified eval — quality varies per upstream skill.

## Portability

Path table is useful adapter reference; copying skills wholesale violates synthesis principle.

## Strengths

- Single map of host skill directories
- Surfaces official skills from many vendors

## Weaknesses / Trade-offs

- Scale invites stale/duplicate/low-quality entries
- Popularity-driven discovery anti-pattern
- Many entries may duplicate agentskills.io examples with tweaks

## Interesting Implementation Details

- Links to MCP server mirroring the list (awesome-agent-skills-mcp)
- Table cites Cursor docs URL for skills

## Relevant Files

- README Skills Paths table (~642 lines in snapshot)

## Evidence

- GitHub README fetch (2026-09-07)

## Relevance to b3-ai-engineering

Use for **discovery during future research phases**, not as implementation source. Path table informs adapter docs.

## Initial Recommendation

OBSERVE for discovery; REJECT bulk import as system foundation
