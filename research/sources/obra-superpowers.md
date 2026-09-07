# Superpowers (obra/superpowers)

## Source

- https://github.com/obra/superpowers
- https://github.com/obra/superpowers-marketplace

## Tier

Tier 2

## Purpose

Composed methodology as Claude Code plugin skills: brainstorming → plan → subagent-driven development → TDD → review.

## Architecture

Skills in `skills/` including:
- `using-superpowers`, `brainstorming`, `writing-plans`, `executing-plans`, `subagent-driven-development`
- `test-driven-development`, `systematic-debugging`, `requesting-code-review`, `receiving-code-review`, `verification-before-completion`
- `writing-skills` (includes skill testing methodology)

Marketplace bundles plugins; SessionStart context injection documented in marketplace README.

## Important Patterns

- **Mandatory workflow** via skill triggering (not optional suggestions)
- Subagent per task with two-stage review (spec compliance, then quality)
- TDD RED-GREEN-REFACTOR enforcement skill
- Cross-tool install tables (Codex, Cursor, Copilot, etc.) — adapter paths documented
- `verification-before-completion` as explicit gate skill

## Skill Design

Standard SKILL.md per skill; methodology split into many small skills (good composability).

## Rules / Instructions

Methodology encoded as skills + SessionStart injection — blurs rule/skill boundary.

## Agents

Subagent-driven-development skill orchestrates worker subagents.

## Commands / Workflows

Implicit workflow via skill chain; marketplace mentions `/brainstorm`, `/write-plan`, `/execute-plan`.

## Evaluation

`writing-skills` skill documents testing skills; ecosystem emphasis on discipline not automated CI evals in repo root.

## Portability

Skills content largely portable markdown; SessionStart/hooks/marketplace not portable.

## Strengths

- Demonstrates **small composable skills** vs monolith
- Strong verification/TDD/review separation
- Wide cross-tool installation documentation

## Weaknesses / Trade-offs

- Can feel rigid ("enthusiastic junior engineer" planning tone)
- SessionStart injection = always-on flavor via hooks — token cost
- Popularity ≠ proof for all teams (community hype risk)

## Interesting Implementation Details

- Official Claude plugin marketplace listing
- Explicit parallel agents skill (`dispatching-parallel-agents`)

## Relevant Files

- `skills/` listing (14 top-level skills inspected via GitHub API)
- `superpowers-marketplace/README.md`

## Evidence

- GitHub API `skills/` directory (2026-09-07)
- Marketplace README snippets

## Relevance to b3-ai-engineering

Validates composable engineering skills + verification-before-completion; caution on hook-based mandatory enforcement.

## Initial Recommendation

ADAPT (skill decomposition and verification gate); REJECT copying full Superpowers stack verbatim
