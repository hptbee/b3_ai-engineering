# Review loop patterns

## Observation

Converging review loops share: **independent review**, **structured findings**, **fix→verify**, **iteration cap**, **artifact persistence**. Failures: shared context self-review, unbounded loops, treating silence as pass, unvalidated findings.

## Evidence

- SWE-Review: independent reconstruction, JSON report, max 3 rounds, trace dir
- dev-loop: validate findings before fix; dual reviewer stop; max 4; JSON state
- calimero: consensus scoring; delta convergence across PR pushes
- Open Code Review: discourse + multi-round dirs
- hamelsmu: stop hook gate (weaker iteration)
- Anthropic evaluator-optimizer pattern

## Pattern

```text
scope → understand → review dimensions → findings (severity ≠ confidence)
→ fix mapped to ids → verify evidence → re-review affected → stop(clean | cap | stagnation)
```

Independent reviewer must not share implementer's unchecked narrative.

## Why it matters

Review loops that share one voice falsely converge; loops without caps waste tokens; loops without verification produce "LGTM" theater.

## Trade-offs

Independent reconstruction (SWE-Review) is token-expensive but reduces anchoring

## Potential application

b3 review-loop spec already aligned well at research time (then cited as `docs/review-loop.md`; **current** files: `review-loop/spec.md`, `review-loop/strategy.md`). Orchestration later added: stagnation detection, validated findings, iteration cap. Reconstruction remains optional for critical paths. Host plugin and product-repo verification remain out of band.

## Confidence

High
