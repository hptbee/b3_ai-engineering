# Review-loop evals

Scenarios for **`docs/review-loop.md`** behavior when runtime exists. Manual review until automated loop runner ships.

| Folder | Cases | Question |
| --- | ---: | --- |
| `false-positive/` | 1 | Is speculative noise treated as confirmed? |
| `false-convergence/` | 2 | Does the loop fake a PASS? |
| `tool-failure/` | 2 | Failed tools → INCOMPLETE? |
| `iteration-limit/` | 1 | Exhausted budget → INCOMPLETE? |
| `finding-lifecycle/` | 2 | Do status and severity≠confidence hold? |

Each YAML file includes `scenario`, `expected_outcome`, and `failure_mode`.

Validate: `./scripts/validate-evals.sh`
