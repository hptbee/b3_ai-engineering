# Vercel React Best Practices agent skill

## Source

https://github.com/vercel-labs/agent-skills — `skills/react-best-practices/SKILL.md`

## Tier

Tier 2

## Purpose

High-quality OSS agent skill: React/Next.js performance optimization as categorized rule catalog with progressive disclosure.

## Architecture

```text
react-best-practices/
├── SKILL.md           # index: 70 rules, 8 categories, priority table
├── rules/             # one file per rule (incorrect/correct examples)
├── references/        # optional depth
└── AGENTS.md          # compiled full guide
```

- Frontmatter: `name: vercel-react-best-practices`, rich description with trigger phrases
- **Priority-ordered categories**: async waterfalls → bundle → server → client → rerender → rendering → js → advanced
- Rule IDs prefixed by category (`async-`, `bundle-`, `server-`, etc.)

## Important Patterns

- **Index skill + rule files** = progressive disclosure at scale (70 rules without bloating SKILL.md)
- Description explicitly lists triggers: React components, Next.js pages, data fetching, bundle optimization
- Performance-first, not component-design-first (complements react.dev thinking model)
- Server-side section includes RSC-specific rules (no shared module state, serialization, parallel fetching)
- `allowed-tools` not used; relies on agent reading `rules/` on demand

## Skill Design

Strong example of **catalog skill** pattern:
- Main SKILL.md = table of contents + when to apply
- Deep content in `rules/<id>.md`
- Compiled AGENTS.md for always-on host context (host-specific choice)

## Rules / Instructions

Individual rules are prescriptive micro-patterns, not standing project rules. Risk: copying all 70 into b3 would violate minimal-surface principle.

## Agents

No subagents; single skill with optional deep reads.

## Commands / Workflows

Apply when writing/reviewing/refactoring React/Next.js performance-sensitive code.

## Evaluation

No published trigger evals in repo. Description breadth may cause **greedy triggering** on any React task — needs near-miss cases vs generic problem-solving.

## Portability

MIT license. Content is React/Next/Vercel-ecosystem specific — belongs in **domain skills**, not portable core.

## Strengths

- Exemplary progressive disclosure for large rule sets
- Impact-prioritized categories guide agent attention
- Concrete incorrect/correct examples per rule

## Weaknesses / Trade-offs

- Very broad description → activation overlap with problem-solving, code-review
- Next.js/Vercel-specific rules mixed with generic React
- 70 rules too large to adopt wholesale for personal system

## Interesting Implementation Details

- `AGENTS.md` companion for full compiled doc (dual discovery path)
- Category impact labels: CRITICAL / HIGH / MEDIUM / LOW

## Relevant Files

- vercel-labs/agent-skills/skills/react-best-practices/**

## Evidence

- Raw SKILL.md fetched 2026-09-07: 8 categories, 70 rules, rules/ layout, trigger description

## Relevance to b3-ai-engineering

Primary **ADAPT** template for frontend performance skill — extract structure (index + rules/), not content bulk. Do not copy verbatim (decision-006).

## Initial Recommendation

ADAPT — 2–3 focused b3 frontend skills (component design, Next.js RSC, performance review) inspired by structure; REJECT wholesale import
