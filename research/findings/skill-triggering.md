# Skill triggering

## Observation

Activation is driven almost entirely by **`description` in YAML frontmatter** until the skill body loads. Hosts may add scoping (`paths`, nested directories, `disable-model-invocation`).

## Evidence

- agentskills.io optimizing-descriptions + spec progressive disclosure
- Cursor `paths`, nested `.cursor/skills/` auto-scope
- Claude `disable-model-invocation` for slash-only skills
- dreaming.press + spec: near-miss eval suites (~20 queries, 3 runs, 0.5 threshold)

## Pattern

Write descriptions that state:
- what the skill does
- when to use (including non-obvious triggers)
- implicit boundaries vs adjacent skills (near-miss protection)

Separate **should-trigger / should-not-trigger / near-miss** eval buckets.

## Why it matters

Under-triggering wastes authored skills; over-triggering hijacks unrelated tasks. Description edits are **breaking changes** (like API changes).

## Trade-offs

Spec and skill-creator suggest "pushy" descriptions to fight under-triggering — increases false positive risk without evals

## Potential application

Implement `evals/skills/<skill>/` before scaling skill count. b3 skills should encode should-not-trigger in description + body.

## Confidence

High
