# Evaluation fixtures

Philosophy: [`docs/evaluation.md`](../docs/evaluation.md).

**Status:** activation fixtures for foundation + synthesized domain skills. Automated runner and CI **deferred** (decision-005).

```bash
./scripts/validate-evals.sh
```

Schema check only — not semantic scoring. Capability evals **not implemented**.

| Area | Notes |
| --- | --- |
| `skills/` | 2/2/2 minimum per new skill; foundation skills from Track C (incl. simplification/residue detection) |
| `rules/` | comply/violate samples |
| `agents/` | `b3-performance-reviewer` and `b3-architecture-reviewer` activation samples; security still thin |
| `review-loop/` | Spec + orchestration v1 scenarios (incl. performance routing & fix-cycle residue) |
| `workflows/ship/` | Lifecycle scenarios for `/b3-ship` (schema fixtures, including JIT freshness/split/gate). Behavioral Git/install checks: `scripts/validate-ship-behavior.ps1` (simulated). Isolated product smoke: `scripts/smoke-ship-product.ps1` (simulated Git). Live `/b3-ship` agent compliance **NOT VERIFIED** |

See [`../skills/README.md`](../skills/README.md).
