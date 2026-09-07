# Decision 005 — Evaluation approach

## Context

b3 planned eval tree (`evals/skills`, `evals/review-loop`) needs prioritization.

## Options Considered

1. agentskills.io trigger suite first
2. End-to-end SWE-bench style capability benchmarks first
3. No evals until 20+ skills exist
4. Copy skill-creator tooling wholesale into repo

## Evidence

- agentskills optimizing-descriptions (`agentskills-open-standard.md`)
- skill-creator eval scripts (`anthropics-skills.md`)
- dreaming.press CI trigger framing
- b3 `docs/evaluation.md` (activation, capability, safety, convergence)

## Decision

**ADAPT** phased eval investment:

| Phase | Deliverable | Decision |
| --- | --- | --- |
| E1 | Trigger fixtures (should/not/near-miss) for 4 foundation skills | **ADOPT** |
| E2 | Review-loop false-PASS / tool-failure fixtures (manual run) | **ADOPT** |
| E3 | Automated runner + CI | **DEFER** |
| E4 | Capability benchmarks per domain skill | **DEFER** until skill exists |
| Copy skill-creator repo scripts | **REJECT** — adapt methodology, implement minimal local runner later |

## Rationale

Description is the skill API — breaking changes need tests first. Capability evals need stable skills. Full automation costly before payoff.

## Consequences

- Track C created fixture **files** under `evals/` (28 skill activation, 8 review-loop, 4 rule samples); automated runner still deferred
- Near-miss cases required for each new skill before catalog growth
- Trigger threshold: start with spec 0.5 / 3 runs; tighten after baseline

## Confidence

Medium-High
