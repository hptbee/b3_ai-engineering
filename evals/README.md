# Evaluation fixtures

Philosophy: [`docs/evaluation.md`](../docs/evaluation.md).

**Status:** Track C (E1 + E2) — **trigger fixtures and review-loop scenarios exist**. Automated runner and CI **deferred** (decision-005).

Evals cover **activation**, **capability** (deferred), **safety**, and **convergence**.

```text
evals/
├── skills/          # 28 cases — 4 foundation skills × 7 each
├── rules/           # 4 cases — comply/violate samples
└── review-loop/   # 8 scenarios — false convergence, tool failure, etc.
```

## Validate fixtures

```bash
./scripts/validate-evals.sh
```

Checks required YAML keys only — not semantic activation scoring.

## Skill evals

| Skill | should-trigger | should-not-trigger | near-miss |
| --- | ---: | ---: | ---: |
| verification | 3 | 2 | 2 |
| code-review | 3 | 2 | 2 |
| problem-solving | 3 | 2 | 2 |
| research-engineering-patterns | 3 | 2 | 2 |

See [`skills/README.md`](skills/README.md).

## Review-loop evals

Manual scenarios for when review-loop runtime exists. See [`review-loop/README.md`](review-loop/README.md).

## Rule evals

Sample comply/violate cases for foundation rules. See [`rules/README.md`](rules/README.md).

## Deferred

- Automated runner (description similarity / LLM judge)
- CI integration
- Capability (quality) fixtures per skill
- Agent-role evals (`evals/agents/`)
