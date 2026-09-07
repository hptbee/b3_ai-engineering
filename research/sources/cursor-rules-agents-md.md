# Cursor Rules and AGENTS.md (official docs)

## Source

https://cursor.com/docs/context/rules

## Tier

Tier 1

## Purpose

Document persistent instruction layers in Cursor: project rules, user/team rules, and AGENTS.md.

## Architecture

Four rule types: Project (`.cursor/rules/*.mdc`), User, Team (dashboard), AGENTS.md (plain markdown). Rules inject at **start of model context** when applied. Precedence: Team → Project → User (merged; earlier wins on conflict).

## Important Patterns

- Rule activation modes: Always Apply, Apply Intelligently (description), Apply to Specific Files (globs), Apply Manually (@mention)
- AGENTS.md as simple alternative without frontmatter
- Nested AGENTS.md with directory proximity precedence
- Keep rules under ~500 lines; reference files with `@file` instead of inlining

## Skill Design

N/A directly — but "Apply Intelligently" rules are migration candidates to skills per Cursor migration guidance.

## Rules / Instructions

`.mdc` requires frontmatter (`description`, `globs`, `alwaysApply`). Plain `.md` in `.cursor/rules/` is **ignored**. AGENTS.md is freeform markdown sections (build, test, style, security).

## Agents

Rules apply to Agent (Chat), not Cursor Tab or Inline Edit (Cmd+K) for User Rules.

## Commands / Workflows

`/create-rule` generates `.mdc` files. Remote rules import to `.cursor/rules/imported/`.

## Evaluation

No eval system. Operational feedback loop: observe agent mistakes → update rules.

## Portability

AGENTS.md is cross-tool. `.mdc` with Cursor frontmatter is **not** portable — belongs in adapter layer or translated to portable rules markdown without host fields.

## Strengths

- Explicit activation matrix (alwaysApply × description × globs)
- Nested AGENTS.md for monorepos
- Clear "what to avoid" (style guides, edge cases, duplication)

## Weaknesses / Trade-offs

- Two parallel systems (rules + AGENTS.md + skills) confuse authors
- Team rules are free-form text unlike project `.mdc` structure
- Precedence across Team/Project/User requires discipline

## Interesting Implementation Details

- `@filename` inclusion in rules pulls file into context
- Import preserves relative paths under `imported/`

## Relevant Files

- Doc sections: Rule anatomy, Glob examples, AGENTS.md nested support, Team Rules

## Evidence

- https://cursor.com/docs/context/rules (fetched 2026-09-07)

## Relevance to b3-ai-engineering

Supports keeping `rules/` portable and short; AGENTS.md as entry point; Cursor `.mdc` mapping deferred to adapters.

## Initial Recommendation

ADAPT — portable rules as markdown + optional metadata; host activation modes in Cursor adapter only.
