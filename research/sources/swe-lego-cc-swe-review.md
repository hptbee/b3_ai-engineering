# SWE-Review (LegoX/cc-swe-review)

## Source

- https://github.com/SWE-Lego/cc-swe-review
- https://arxiv.org/abs/2607.06065 (paper referenced in README)

## Tier

Tier 2

## Purpose

Claude Code plugin implementing independent reconstruction review and patchgen→review→revise loop.

## Architecture

Plugin with skills:
- `/swe-review:review` — independent review pass
- `/swe-review:resolve` — patchgen → review subagent → revision (max **3 rounds**)

Artifacts saved under `./docs/swe-review/{instance}_{timestamp}/`.

## Important Patterns

- Review as **subagent** without patchgen context (anti-anchoring)
- Reviewer proposes own fix **before** reading patch, then compares
- Point-of-CREATION vs point-of-USE defect classification
- Structured JSON output: decision, confidence, defects
- Loop terminates on approve or max rounds — not on silence

## Skill Design

Skills packaged in plugin `skills/` directory (Claude Code plugin layout).

## Rules / Instructions

Enforced via skill procedures, not separate rules files.

## Agents

Dedicated review subagent role with isolated mandate.

## Commands / Workflows

Two-phase resolve workflow with explicit decision gate (`approve` | `request_changes`).

## Evaluation

Research paper + trace artifacts; not a general skill-trigger eval harness.

## Portability

Workflow concepts portable; JSON schema and plugin paths host-specific.

## Strengths

- Strong answer to self-review bias
- Explicit max iteration
- Traceability directory per run
- Works without requiring test suite as gate

## Weaknesses / Trade-offs

- JSON review schema differs from b3 finding lifecycle — needs mapping
- Fixed 3 rounds may stop early/late without stagnation detection
- Claude Code plugin lock-in

## Interesting Implementation Details

- Symptom-fix detection via independent reconstruction
- Demo GIF + structured report example in README

## Relevant Files

- `README.md`
- `skills/` (plugin)
- `.claude-plugin/`

## Evidence

- README raw (2026-09-07)
- GitHub API root listing

## Relevance to b3-ai-engineering

Strong evidence for independent reviewer, structured findings, iteration cap, artifact trail — central to `decision-004-review-loop`.

## Initial Recommendation

ADAPT (independence + reconstruction + structured output + caps)
