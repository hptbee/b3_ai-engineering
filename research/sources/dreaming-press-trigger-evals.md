# Trigger evals — community methodology article

## Source

https://dreaming.press/posts/how-to-write-trigger-evals-for-an-agent-skill.html

## Tier

Tier 3

## Purpose

Independent articulation of skill **activation** evals (recall/precision) complementing agentskills.io official doc.

## Architecture

N/A — methodology essay.

## Important Patterns

- Trigger eval = deterministic yes/no on skill load (no output grading)
- Recall vs precision framing for under/over triggering
- CI gating on description changes
- Pair with skill version control for revertibility

## Skill Design

Emphasizes description as **sole** trigger surface until skill loads.

## Rules / Instructions

N/A

## Agents

N/A

## Commands / Workflows

N/A

## Evaluation

Core subject — aligns with agentskills.io near-miss suite; adds CI/regression language.

## Portability

Fully portable methodology.

## Strengths

- Clear vocabulary for b3 `evals/skills/` structure
- Stresses description edits as breaking changes

## Weaknesses / Trade-offs

- Blog — not normative spec
- Overlaps heavily with agentskills.io (not independent evidence alone)

## Interesting Implementation Details

- Recommends 30–50 prompts at scale vs spec's ~20

## Relevant Files

- Article sections on recall/precision and CI

## Evidence

- Web search snippets (2026-09-07); cross-check with agentskills.io optimizing-descriptions

## Relevance to b3-ai-engineering

Supports `docs/evaluation.md` activation dimension; cite alongside Tier 1 spec.

## Initial Recommendation

ADAPT (CI + recall/precision language); OBSERVE as sole authority
