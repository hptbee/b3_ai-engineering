# Evaluation fixtures

Philosophy: [`docs/evaluation.md`](../docs/evaluation.md).

**Status:** activation fixtures for foundation + synthesized domain skills. Automated runner and CI **deferred** (decision-005).

```bash
./scripts/validate-evals.sh
```

Schema check only — not semantic scoring. Capability evals **not implemented**.

| Area | Notes |
| --- | --- |
| `skills/` | 2/2/2 minimum per new skill; foundation skills from Track C |
| `rules/` | comply/violate samples |
| `agents/` | `performance-reviewer` activation samples; other roles still thin |
| `review-loop/` | Spec + orchestration v1 scenarios (incl. performance routing) |

See [`../.cursor/skills/README.md`](../.cursor/skills/README.md).
