# Agent design (specialized roles)

## Observation

**Subagents** provide context isolation, parallelism, and independent mandates; distinct from skills (single-purpose, shared context).

## Evidence

- Cursor subagents doc: decision table skills vs subagents; built-in Explore/Bash/Browser
- SWE-Review: review as subagent without patchgen context
- Open Code Review: parallel redundant reviewers + discourse
- Superpowers: subagent-driven-development with two-stage review
- Anthropic effective agents: orchestrator-workers, evaluator-optimizer

## Pattern

Use specialized agents when:
- output is noisy or large (logs, search, browser DOM)
- **independence** required (review vs implement)
- parallel workstreams help

Use skills when task is repeatable, single-context, one-shot or short procedure.

## Why it matters

Self-review bias is a documented failure mode; subagents/reviewer roles are the primary mitigation in multiple review-loop repos.

## Trade-offs

Subagents add latency, cost, orchestration complexity; over-delegation for trivial tasks

## Potential application

b3 `agents/` layer should define portable **mandates** first; host agent files generated later. Review-loop reviewers map to agents, not skills.

## Confidence

High
