# Open Code Review (spencermarx/open-code-review)

## Source

https://github.com/spencermarx/open-code-review

## Tier

Tier 2

## Purpose

Multi-agent PR review orchestration with phased pipeline, redundancy, and multi-round sessions.

## Architecture

8-phase workflow:
1. Context discovery → 2. Change analysis → 3. Tech lead assessment → 4. Parallel reviews → 5. Aggregation → 6. Discourse → 7. Synthesis → 8. Presentation

Multi-round: `round-1/`, `round-2/` … preserved; shared context reused (`discovered-standards.md`, `context.md`).

## Important Patterns

- Configurable reviewer **team** with redundancy
- Discourse phase: reviewers challenge each other's findings
- Incremental rounds after feedback addressed
- Dashboard + `/ocr-review`, `/ocr-address` commands
- OpenSpec integration for standards discovery

## Skill Design

Claude plugin with `.claude/` agents/skills layout (inspected root: `.claude`, `.claude-plugin`, `.claude-flow`).

## Rules / Instructions

`discovered-standards.md` emerges from repo — dynamic rules/context, not static only.

## Agents

Multiple parallel reviewer agents + tech lead orchestrator pattern.

## Commands / Workflows

Explicit slash commands for review and address phases; human approval steps in address flow.

## Evaluation

No published trigger evals; quality via multi-agent redundancy and discourse.

## Portability

Phase model portable; OCR-specific storage layout and dashboard not portable.

## Strengths

- Explicit aggregation + dedup + discourse reduces noise
- Multi-round with preserved artifacts
- Separates review from address implementation

## Weaknesses / Trade-offs

- High complexity / token cost
- Risk of false convergence if discourse averages away disagreement without resolution
- Heavy `.claude` coupling

## Interesting Implementation Details

- Redundant reviewers examining same diff
- Round completion gate before starting next round

## Relevant Files

- README (720 lines fetched to agent-tools)
- `.claude/` tree

## Evidence

- GitHub repo page fetch (2026-09-07)
- API root listing

## Relevance to b3-ai-engineering

Informs review-loop runtime: phases, rounds, shared context, separate address step — compare with simpler SWE-Review loop.

## Initial Recommendation

ADAPT (phased review + rounds + address separation); REJECT full 8-phase default for v1 (too heavy)
