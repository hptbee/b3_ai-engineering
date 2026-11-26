# Rule evals

Comply / violate samples covering all 5 canonical rules (`engineering-principles`, `evidence-and-provenance`, `portability`, `simplest-correct`, and `verification`).

| Rule | Comply fixture | Violate fixture |
| --- | --- | --- |
| `rules/engineering-principles.md` | `engineering-principles/comply-smallest-change.yaml` | `engineering-principles/violate-layer-confusion.yaml` |
| `rules/evidence-and-provenance.md` | `comply/evidence-provenance-recorded.yaml` | `violate/evidence-verbatim-copy.yaml` |
| `rules/portability.md` | `portability/comply-thin-adapter.yaml` | `portability/violate-forked-host-meaning.yaml` |
| `rules/simplest-correct.md` | `comply/simplest-correct-named-requirement.yaml` | `violate/simplest-correct-prestige.yaml` |
| `rules/verification.md` | `comply/verification-reports-failure.yaml` | `violate/verification-fake-pass.yaml` |

Validate: `cargo test --test eval_contracts`
