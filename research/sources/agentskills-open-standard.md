# Agent Skills Open Standard (agentskills.io)

## Source

- https://github.com/agentskills/agentskills
- https://agentskills.io/specification (via `docs/specification.mdx` in repo)
- https://agentskills.io/skill-creation/optimizing-descriptions

## Tier

Tier 1

## Purpose

Vendor-neutral specification for SKILL.md skills: structure, validation, progressive disclosure, and trigger testing methodology.

## Architecture

Three-phase loading:
1. Metadata (~100 tokens) — all skills at startup
2. Instructions (<5000 tokens recommended; SKILL.md <500 lines)
3. Resources on demand — `scripts/`, `references/`, `assets/`

## Important Patterns

- Required `name` + `description`; strict naming validation
- Optional `license`, `compatibility`, `metadata`, `allowed-tools` (experimental)
- Trigger eval suite: ~20 queries, should/should-not + **near-misses**, 3 runs/query, 0.5 threshold
- Train/validation split for description optimization (avoid overfitting queries)

## Skill Design

Folder = skill name. Body has no format restriction but spec recommends concise procedural markdown.

## Rules / Instructions

Out of scope — spec is skills-only.

## Agents

Out of scope.

## Commands / Workflows

Out of scope.

## Evaluation

**Authoritative trigger eval methodology** published alongside spec. Emphasizes near-miss negatives and nondeterministic trigger rates.

## Portability

This **is** the portability anchor for b3-ai-engineering skill files.

## Strengths

- Cross-vendor adoption (Cursor, Claude, Codex, Copilot, Gemini per ecosystem tables)
- Explicit progressive disclosure token budget
- Concrete eval recipe for descriptions

## Weaknesses / Trade-offs

- `allowed-tools` experimental — inconsistent support
- Description optimization guidance encourages "pushy" descriptions — precision/recall tradeoff
- Spec does not cover rules, agents, review loops

## Interesting Implementation Details

- Invalid name examples documented (uppercase, leading hyphen, consecutive hyphens)
- Good vs poor description examples in spec

## Relevant Files

- `agentskills/agentskills/docs/specification.mdx`
- `docs/skill-creation/optimizing-descriptions.mdx`

## Evidence

- Raw specification.mdx (2026-09-07)
- optimizing-descriptions.mdx (2026-09-07)

## Relevance to b3-ai-engineering

Directly aligns with existing `docs/skill-standard.md`. Should cite this as external authority for SKILL.md shape and eval buckets.

## Initial Recommendation

ADOPT (spec shape and eval methodology); ADAPT (wording/tone — avoid over-pushy descriptions without eval data)
