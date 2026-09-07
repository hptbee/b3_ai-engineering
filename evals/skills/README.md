# Skill evals

Activation cases per skill:

```text
<skill>/
├── should-trigger/
├── should-not-trigger/
└── near-miss/
```

## Foundation skills (implemented)

| Skill | Path |
| --- | --- |
| verification | `verification/` — 7 cases |
| code-review | `code-review/` — 7 cases |
| problem-solving | `problem-solving/` — 7 cases |
| research-engineering-patterns | `research-engineering-patterns/` — 7 cases |

Each case is a YAML file with: `id`, `artifact`, `intent`, `input`, `expected_bucket` (and optional `preferred_skill`, `notes`).

## Running

Manual: read skill description + case `input`; judge whether the skill should activate.

Automated runner: **not implemented** (decision-005 E3 deferred).

Validate schema: `./scripts/validate-evals.sh`

## Adding cases

Add when:
- a new skill ships (minimum 2 per bucket before catalog growth)
- a near-miss misfire is observed in real use
- description text changes (re-run all buckets)

Capability (quality) fixtures can sit beside activation buckets when stable skills exist.
