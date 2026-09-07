# AI Code Reviewer (calimero-network/ai-code-reviewer)

## Source

https://github.com/calimero-network/ai-code-reviewer

## Tier

Tier 2

## Purpose

Production multi-agent PR review service with consensus scoring, delta tracking, and convergence logic.

## Architecture

Parallel agents (security, patterns, logic, performance, style) → aggregator clusters findings → consensus scores → ranked output. GitHub webhook integration. Incremental reviews track new/fixed/open findings across pushes.

## Important Patterns

- **Consensus-based scoring** to reduce false positives
- Separate severity from multi-agent agreement
- Delta/convergence: stop when findings stabilize across pushes
- Config-driven agents (`.ai-reviewer.yaml`)
- Rule-based doc review (checks CLAUDE.md/AGENTS.md updates) without LLM

## Skill Design

Uses `.ai/` rules directory referenced in config (` .ai/rules/`). Not SKILL.md-first.

## Rules / Instructions

YAML config + `.ai/rules/` module conventions; agent `custom_prompt_append`.

## Agents

Named reviewers with focus_areas, model overrides, tool use flags, temperature.

## Commands / Workflows

CLI `review-pr`; GitHub automation.

## Evaluation

Operational metrics via consensus; no skill-trigger evals. Doc-check is deterministic rules.

## Portability

Architecture patterns portable; YAML schema and GitHub coupling not portable.

## Strengths

- Explicit convergence on PR delta
- Multi-model cost optimization (Haiku for style)
- Separates LLM review from doc drift checks

## Weaknesses / Trade-offs

- Heavy infrastructure (API keys, webhooks)
- Consensus can suppress valid minority findings
- Config complexity

## Interesting Implementation Details

- `max_combined_context_tokens`, per-file byte limits in config
- Anthropic prompt caching enabled

## Relevant Files

- `.ai-reviewer.yaml` (inspected first 80 lines)
- `.ai/` directory

## Evidence

- Raw `.ai-reviewer.yaml` (2026-09-07)
- README/search snippets

## Relevance to b3-ai-engineering

Evidence for finding clustering, consensus/confidence separation, incremental review convergence.

## Initial Recommendation

ADAPT (consensus + delta convergence concepts); DEFER full YAML agent config until runtime exists
