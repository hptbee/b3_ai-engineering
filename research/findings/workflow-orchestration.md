# Workflow orchestration

## Observation

Reliable systems combine **fixed phase graphs** (implement → review → fix → verify) with explicit gates; autonomy increases only where measured.

## Evidence

- Anthropic: prompt chaining, routing, orchestrator-workers, evaluator-optimizer
- Superpowers: brainstorming → plan → execute → TDD → review skills chain
- SWE-Review resolve: patchgen → review → revision (max 3)
- dev-loop: plan critique → implement → dual review → fix loop (max 4 iterations)
- Open Code Review: 8-phase pipeline + multi-round folders

## Pattern

Workflow = ordered phases + stop conditions + artifact trail (logs, JSON reports, round directories).

## Why it matters

Ad-hoc agent improvisation drifts under pressure (Superpowers addresses with mandatory skills).

## Trade-offs

Heavy pipelines (OCR 8 phases) improve thoroughness but explode token/time cost — not default for personal system v1

## Potential application

b3 default loop already matches industry baseline. Implement `workflows/` only for repeated multi-step sequences after evidence of repetition.

## Confidence

Medium-High
