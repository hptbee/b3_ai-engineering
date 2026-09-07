# Decision 001 — Skill core format

## Context

b3 needs a portable skill shape before domain skills are synthesized.

## Options Considered

1. **agentskills.io SKILL.md standard** (folder + frontmatter + optional dirs)
2. Cursor-only `.mdc` rules as skills substitute
3. Monolithic markdown playbooks without frontmatter
4. Per-host duplicated skill trees

## Evidence

- Tier 1: agentskills spec, Cursor, Claude, Codex docs (`research/sources/agentskills-open-standard.md`, etc.)
- Recurring pattern: progressive disclosure (6+ sources)
- Anti-pattern: platform-forked cores (`research/findings/anti-patterns.md`)

## Decision

**ADOPT** agentskills.io-compatible `skills/<name>/SKILL.md` as portable core.

## Rationale

Cross-vendor convergence; b3 `docs/skill-standard.md` already matches; adapters map host paths without forking text.

## Consequences

- Optional fields (`license`, `compatibility`, `metadata`) used when helpful
- Host extensions (`paths`, `disable-model-invocation`, hooks) documented only under `adapters/`
- Domain skills must pass trigger eval sketches before promotion from research

## Confidence

High
