# Evaluation systems comparison

| System | Activation / trigger | Capability | Regression | Safety (fail-closed) | Automation | Format |
| --- | --- | --- | --- | --- | --- | --- |
| **agentskills.io** | ★ Near-miss suite, 3 runs, 0.5 threshold | Manual quality review | Hold-out val queries | Not specified | Bash example script | JSON queries |
| **skill-creator** | Description optimizer + benchmarks | eval-viewer UI, variance analysis | Iterative skill edits | Partial | Scripts in skill | Mixed files under skill |
| **dreaming.press** | Recall/precision, CI gate | Separate output evals | Version control revert | Implicit | CI | Labeled prompts |
| **b3 (planned)** | should/not/near-miss buckets | Skill quality rubric | Future eval dirs | UNKNOWN not PASS | Not implemented | `evals/` tree |
| **dev-loop** | N/A | Production usage | PR iteration | Validates findings | Hooks + JSON state | Operational |
| **calimero** | N/A | Consensus quality | PR delta | Config limits | GitHub webhooks | YAML + runtime |
| **Anthropic parallelization** | N/A | Multi-reviewer voting | Eval automation pattern | Guardrails pattern | Conceptual | N/A |

## Consensus

Trigger evals are **first-class** for skills (description is API). Capability evals remain harder and often manual.

Separate activation from output quality — dreaming.press + spec agree.

## Disagreements

- **Threshold 0.5** vs stricter CI gates — spec default may be loose for production gates
- **Eval automation investment:** only skill-creator goes deep; most review repos have none

## Implication for b3

Implement trigger eval fixtures for 4 foundation skills first; add review-loop false-PASS fixtures second; defer full automation runner (DEFER in decision-005).
