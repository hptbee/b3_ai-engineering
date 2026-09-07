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
| `review-loop/` | Track C scenarios |
| `agents/` | no activation cases yet — roles are thin mandates |

See [`skills/README.md`](skills/README.md).
