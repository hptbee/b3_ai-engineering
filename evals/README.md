# Evaluation fixtures

Philosophy: [`docs/evaluation.md`](../docs/evaluation.md).

**Status:** `338` YAML activation, boundary, rule, review-loop, command, and workflow fixtures across 6 top-level categories. Automated LLM runner and CI **deferred** (decision-005).

```bash
cargo test --test eval_contracts
```

Schema check + native orchestration/context/command contract assertions — not semantic LLM scoring. Capability evals **not implemented**.

| Area | Cases | Notes |
| --- | ---: | --- |
| `skills/` | 176 | `2/2/2` minimum across all `24` canonical skills (`should-trigger`, `should-not-trigger`, `near-miss`), including `6` fixtures in `skills/pr-feedback/`, `9` in `skills/simplest-correct/`, and `14` in `skills/code-review/` |
| `rules/` | 10 | Comply/violate samples across `comply/` (`3`), `violate/` (`3`), `engineering-principles/` (`2`), and `portability/` (`2`) |
| `agents/` | 7 | `b3-architecture-reviewer` (`3`, incl. `design-only`) and `b3-performance-reviewer` (`4`); security still thin |
| `review-loop/` | 32 | Spec + orchestration scenarios across all `8` subfolders (`adaptive-sizing/`, `orchestration/`, `quality-gate/`, `false-positive/`, `false-convergence/`, `tool-failure/`, `iteration-limit/`, `finding-lifecycle/`; see [`review-loop/README.md`](review-loop/README.md) and `cargo test --test eval_contracts`) |
| `commands/` | 27 | Standalone, daily engineering (`research`, `audit`, `refactor`), PR-feedback, and canonical orchestration command boundaries, verify provenance, and loop convergence (`evals/commands/` + `cargo test --test eval_contracts`) |
| `workflows/orchestration/` | 22 | Semantic orchestration scenarios for adaptive scheduling, event-driven `A..E` continuous release, active-worker write/RW/slot admission, incremental isolated-WT integration (`--worker-bases`), mid-wave resume, 4 isolation modes, single-writer PR/evidence governance, `DISPUTED`/failure isolation, staleness rejection, and reviewer independence |
| `workflows/ship/` | 50 | Lifecycle scenarios for `/b3-ship` (4-mode wave partitioning, ownership provenance, JIT freshness, context routing, verify receipts). Live `/b3-ship` agent compliance **NOT VERIFIED** |
| `workflows/research-ship/` | 14 | Research-first delivery scenarios for `/b3-research-ship` (evidence freshness, contradictory sources, domain-unit isolation, governance/editorial gates, provider-neutral `merge-policy-check`, and resume). Live host/PR compliance **NOT VERIFIED** |

See [`../skills/README.md`](../skills/README.md).
