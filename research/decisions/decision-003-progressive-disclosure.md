# Decision 003 — Progressive disclosure

## Context

Skills must scale without blowing always-on context.

## Options Considered

1. Three-tier model (metadata → SKILL.md → references/scripts)
2. Single large SKILL.md for simplicity
3. Always-on reference files in `references/` repo root
4. External wiki links only

## Evidence

- agentskills.io token budgets (`agentskills-open-standard.md`)
- MS Agent Framework tool-based resource loading
- skill-creator domain-split references (`anthropics-skills.md`)
- Anti-pattern: monolithic skills (`anti-patterns.md`)

## Decision

**ADOPT** three-tier progressive disclosure; enforce concise SKILL.md with on-demand references/scripts.

## Rationale

Strongest cross-vendor consensus; aligns with existing b3 skill standard.

## Consequences

- Authoring checklist: index references in SKILL.md with when-to-open guidance
- Large skills must split before merge from research
- `assets/` optional fourth dir — adopt when templates needed (Cursor/Claude convention)

## Confidence

High
