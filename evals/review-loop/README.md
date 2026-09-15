# Review-loop evals

Scenarios for **`review-loop/spec.md`** and **`review-loop/strategy.md`**. Manual judge until an automated loop runner ships.

| Folder | Cases | Question |
| --- | ---: | --- |
| `false-positive/` | 2 | Is speculative noise or unconfirmed redundancy treated as confirmed/deleted? |
| `false-convergence/` | 2 | Does the loop fake a PASS? |
| `tool-failure/` | 2 | Failed tools → INCOMPLETE? |
| `iteration-limit/` | 1 | Exhausted budget → INCOMPLETE? |
| `finding-lifecycle/` | 2 | Do status and severity≠confidence hold? |
| `adaptive-sizing/` | 4 | Small stays full-PR; large does not full-rereview every fix; no tiny units; no 10×5×full-PR |
| `quality-gate/` | 1 | LOW remaining + blockers gone + tests PASS → PASS? |
| `orchestration/` | 6 | One trigger vs stop-after-first-review; `review` stays single-pass; Reviewer/Fixer dispatched separately; performance-reviewer skip vs hot-path; fix-cycle residue detection |

Each YAML file includes `scenario`, `expected_outcome`, and `failure_mode`.

Validate: `./scripts/validate-evals.sh`
