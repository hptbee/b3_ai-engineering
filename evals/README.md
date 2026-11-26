# Evaluation fixtures

Philosophy: [`docs/evaluation.md`](../docs/evaluation.md).

**Status:** `304` YAML activation, boundary, rule, review-loop, and workflow fixtures across 6 top-level categories. Automated LLM runner and CI **deferred** (decision-005).

```bash
./scripts/validate-evals.sh
```

Schema check only — not semantic scoring. Capability evals **not implemented**.

| Area | Cases | Notes |
| --- | ---: | --- |
| `skills/` | 181 | `2/2/2` minimum across all `24` canonical skills (`should-trigger`, `should-not-trigger`, `near-miss`), including `6` fixtures in `skills/pr-feedback/` (`scripts/validate-pr-feedback.ps1`), `10` in `skills/simplest-correct/`, and `18` in `skills/code-review/` |
| `rules/` | 10 | Comply/violate samples across `comply/` (`3`), `violate/` (`3`), `engineering-principles/` (`2`), and `portability/` (`2`) |
| `agents/` | 7 | `b3-architecture-reviewer` (`3`, incl. `design-only`) and `b3-performance-reviewer` (`4`); security still thin |
| `review-loop/` | 26 | Spec + orchestration scenarios across all `8` subfolders (`adaptive-sizing/`, `orchestration/`, `quality-gate/`, `false-positive/`, `false-convergence/`, `tool-failure/`, `iteration-limit/`, `finding-lifecycle/`; see [`review-loop/README.md`](review-loop/README.md), `scripts/validate-tshirt-hierarchical.ps1`, and `scripts/validate-merge-security.sh`) |
| `commands/` | 16 | Standalone & PR-feedback command activation boundaries, verify provenance, and loop convergence (`evals/commands/` + `scripts/validate-standalone-commands.ps1` & `scripts/validate-pr-feedback.ps1`) |
| `workflows/ship/` | 50 | Lifecycle scenarios for `/b3-ship` (4-mode wave partitioning, ownership provenance, JIT freshness, context routing, verify receipts). Behavioral suites: `scripts/validate-ship-behavior.ps1`, `scripts/validate-context-routing.ps1`, `scripts/smoke-ship-product.ps1`. Live `/b3-ship` agent compliance **NOT VERIFIED** |
| `workflows/research-ship/` | 14 | Research-first delivery scenarios for `/b3-research-ship` (evidence freshness, contradictory sources, domain-unit isolation, governance/editorial gates, provider-neutral `merge-policy-check`, and resume). Behavioral dual-shell checks: `scripts/validate-research-ship.ps1` & `scripts/validate-merge-security.sh`. Live host/PR compliance **NOT VERIFIED** |

See [`../skills/README.md`](../skills/README.md).
