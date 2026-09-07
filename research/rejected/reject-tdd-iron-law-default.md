# Reject — Superpowers TDD iron law as B3 default

## Considered

Adopt Superpowers `test-driven-development` as always-on: no production code without a failing test first; delete existing implementation if written first.

## Evidence

- obra/superpowers `skills/test-driven-development/SKILL.md` (fetched 2026-09-07)
- B3 `rules/engineering-principles.md` (smallest change)
- B3 `skills/engineering/verification` (evidence after change)
- Profile: Tùng works in mixed brownfield .NET/React systems where tests-after on existing modules is often the honest path

## Why rejected as default

- Conflicts with smallest-change and brownfield reality
- “Delete hours of work” is process theater, not verification
- Mandatory TDD on config, UI layout, Three.js scene glue produces weak tests
- B3 already forbids fake PASS; TDD-always does not add honesty

## Decision

**REJECT** as default skill/rule.

## Alternative

`skills/engineering/testing-strategy`: prefer a failing test for **new behavior and bug fixes** when the environment supports it; always verify with evidence; never claim tests passed without running them.
