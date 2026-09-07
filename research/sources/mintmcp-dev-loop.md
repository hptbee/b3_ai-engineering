# dev-loop (mintmcp/dev-loop)

## Source

https://github.com/mintmcp/dev-loop

## Tier

Tier 2

## Purpose

Autonomous implement→dual-review→fix loop using Codex + Claude with hooks and persisted state.

## Architecture

Phases: plan self-critique → implement (clean subagent) → PR → **Codex review** (read-only sandbox) → Claude fixes → **Claude parallel review agents** (code-reviewer, silent-failure-hunter, code-simplifier) with finding validation → repeat until both reviewers report zero validated issues or **max iterations (default 4)**.

State in JSON file; compaction-safe. Stop hook prevents exit mid-loop.

## Important Patterns

- **Cross-model** review (Codex finds, Claude fixes with intent context)
- Validate findings against code before acting (false positive discard)
- Parallel specialized reviewers
- PR comment per iteration (external visibility)
- Hooks inject phase reminders

## Skill Design

Under `dev-loop/skills/` (path from search snippets; plugin layout).

## Rules / Instructions

Hook-driven phase enforcement rather than markdown rules.

## Agents

Multiple review subagents + implement subagent; Codex as external reviewer process.

## Commands / Workflows

Full dev loop workflow — not a single skill.

## Evaluation

Implicit eval: finding validation step before fix. No skill-trigger eval suite.

## Portability

Pattern valuable; hook + JSON state + dual-model setup highly host-specific.

## Strengths

- Addresses false positive noise explicitly
- Iteration cap with dual stop condition
- Survives context compaction via external state

## Weaknesses / Trade-offs

- 30+ minute runs; expensive
- Convergence = "zero validated issues" — still risk if validation weak
- Tight coupling to Codex CLI + Claude Code hooks

## Interesting Implementation Details

- Up to 8 review cycles (4 Codex + 4 Claude passes)
- Codex read-only sandbox for review separation

## Relevant Files

- `README.md`
- `dev-loop/` plugin directory
- `.claude-plugin/`

## Evidence

- GitHub README/search snippets (2026-09-07)
- API listing repo root

## Relevance to b3-ai-engineering

Evidence for: finding validation, iteration limits, externalized state, specialized reviewers — adapt concepts without dual-model requirement initially.

## Initial Recommendation

ADAPT (validation-before-fix, iteration cap, state file); DEFER cross-model review until needed
