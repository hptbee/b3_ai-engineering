# claude-review-loop (hamelsmu/claude-review-loop)

## Source

https://github.com/hamelsmu/claude-review-loop

## Tier

Tier 2

## Purpose

Claude Code plugin: task phase → Codex multi-agent review on stop hook → address findings.

## Architecture

Stop hook intercepts agent exit:
1. Task phase — Claude implements
2. On stop: prepare Codex runner script → Claude runs Codex (parallel subagents) → writes `reviews/review-*.md` → addressing phase

Review agents (conditional):
- Diff Review (always)
- Holistic Review (always)
- Next.js Review (conditional)
- UX Review (conditional, browser E2E)

## Important Patterns

- **Stop hook** enforces review before session ends
- Codex multi-agent parallel review from Claude session
- State file `.claude/review-loop.local.md` tracks phase
- Project-type conditional reviewers

## Skill Design

Plugin under `plugins/`; `/review-loop` command.

## Rules / Instructions

Phase state in local markdown file.

## Agents

Codex subagents spawned for review; Claude addresses.

## Commands / Workflows

Two-phase state machine: `task` → `addressing`.

## Evaluation

No trigger evals.

## Portability

Hook + Codex runner scripts are Claude/Codex specific; conditional reviewer roster concept portable.

## Strengths

- Hard gate: cannot "finish" without review pass
- Parallel review specialization
- Written review artifacts on disk

## Weaknesses / Trade-offs

- Single review pass per stop (not full iterate-until-clean loop in basic flow)
- Depends on Codex availability
- False convergence if Claude ignores review file

## Interesting Implementation Details

- Auto-enables Codex multi-agent in config on first use
- Streams Codex output to user during review

## Relevant Files

- `plugins/` directory
- `.claude/review-loop.local.md` state pattern (documented in README)

## Evidence

- GitHub README/search (2026-09-07)

## Relevance to b3-ai-engineering

Supports mandatory verification gate and specialized reviewers; weaker on iteration/stagnation vs SWE-Review/dev-loop.

## Initial Recommendation

ADAPT (mandatory review gate, conditional reviewers); OBSERVE hook mechanism for Claude adapter only
