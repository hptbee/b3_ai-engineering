# Evaluation patterns

## Observation

Mature skill ecosystems treat **activation evals** (trigger) separately from **capability evals** (output quality). Trigger evals use labeled prompts, near-misses, multi-run rates, train/val splits.

## Evidence

- agentskills.io optimizing-descriptions (authoritative procedure)
- anthropics skill-creator: eval-viewer, benchmarks, description optimizer scripts
- dreaming.press: recall/precision, CI gating
- Anthropic effective agents: parallel evaluators for model behavior

Review-loop systems embed **finding validation** (dev-loop) and **consensus** (calimero) rather than separate eval suites.

## Pattern

| Eval type | Question | Fixture shape |
| --- | --- | --- |
| Activation | Did right skill load? | should / should-not / near-miss prompts |
| Capability | Did skill produce good result? | Task + expected properties |
| Safety | Fail closed on tool failure? | Broken tool scenarios |
| Convergence | Did review loop improve code? | Known-bug diffs |

## Why it matters

b3 eval philosophy matches industry direction — implementation still deferred.

## Trade-offs

Trigger evals are nondeterministic — require multi-run thresholds; CI cost non-trivial

## Potential application

First eval investment: foundation 4 skills trigger buckets + review-loop false-PASS fixtures.

## Confidence

High for activation; Medium for review-loop automated eval (few open examples)
