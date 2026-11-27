# Review-loop evals

Scenarios (`26` YAML cases across `8` folders) for **`review-loop/spec.md`**, **`review-loop/strategy.md`**, and **`review-loop/hierarchical.md`**. Manual judge for prompt cases until an automated loop runner ships; deterministic inventory, ledger, and eval schema gates are exercised by `cargo test --test eval_contracts` and native `b3` integration tests.

| Folder | Cases | Question |
| --- | ---: | --- |
| `false-positive/` | 2 | Is speculative noise or unconfirmed redundancy treated as confirmed/deleted? |
| `false-convergence/` | 2 | Does the loop fake a PASS? |
| `tool-failure/` | 2 | Failed tools → INCOMPLETE? |
| `iteration-limit/` | 1 | Exhausted budget → INCOMPLETE? |
| `finding-lifecycle/` | 2 | Do status and severity≠confidence hold? |
| `adaptive-sizing/` | 8 | 6-tier T-shirt sizing (`XS`..`XXL`), delta re-review, hierarchical `L0`–`L4` cohesive unit bounds, and decoupled risk specialist dispatch |
| `quality-gate/` | 1 | LOW remaining + blockers gone + tests PASS → PASS? |
| `orchestration/` | 8 | One trigger vs stop-after-first-review; `b3-review` stays single-pass; Reviewer/Fixer dispatched separately; specialist skip vs hot-path; fix-cycle residue detection; `SINGLE_AGENT_LIMIT` honesty |

Each YAML file includes `scenario`, `expected_outcome`, and `failure_mode`.

Validate: `cargo test --test eval_contracts`
