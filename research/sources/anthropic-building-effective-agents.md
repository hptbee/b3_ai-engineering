# Anthropic — Building Effective Agents

## Source

https://www.anthropic.com/engineering/building-effective-agents (Dec 19, 2024; note on page points to Managed Agents for newer tooling)

## Tier

Tier 1

## Purpose

Engineering guidance on agentic patterns: when to use workflows vs agents, composable patterns, tool design.

## Architecture

Distinction:
- **Workflows** — LLM steps orchestrated by predefined code paths
- **Agents** — LLM directs its own process/tool use

Patterns: prompt chaining, routing, parallelization (sectioning/voting), orchestrator-workers, evaluator-optimizer loop, autonomous agent with checkpoints.

## Important Patterns

- Start simple; add complexity only when measured improvement
- Evaluator-optimizer = explicit review/refinement loop
- Parallelization for multi-perspective review (voting)
- Tool/format design as important as prompts (SWE-bench anecdote: absolute paths)
- Prefer direct API over heavy frameworks unless needed

## Skill Design

Not covered (predates Agent Skills standard prominence).

## Rules / Instructions

Implicit: transparency, show planning steps, maintain simple designs.

## Agents

Autonomous agents need stopping conditions, sandbox testing, human checkpoints. Coding agents effective because tests give verifiable feedback.

## Commands / Workflows

Workflow catalog is conceptual — maps to orchestration layer design.

## Evaluation

Emphasizes measurement before adding agentic complexity. Parallelization pattern explicitly mentions automating evals.

## Portability

Patterns are host-agnostic concepts; not file-format spec.

## Strengths

- Strong "don't over-agent" message
- Evaluator-optimizer directly supports review-loop thinking
- Tool ACInterface (ACI) guidance transferable to MCP/skills scripts

## Weaknesses / Trade-offs

- Not a file-layout standard
- Some advice superseded by skills/subagents products
- Framework list may be stale

## Interesting Implementation Details

- Customer support and coding called out as high-fit agent domains
- Appendix on tool parameter naming and poka-yoke

## Relevant Files

- Full article sections + Appendix 2

## Evidence

- Article fetched 2026-09-07

## Relevance to b3-ai-engineering

Conceptual backing for workflows, review loops, verification, iteration limits, and skepticism toward mega-frameworks.

## Initial Recommendation

ADOPT (patterns and principles); OBSERVE Managed Agents product specifics separately
