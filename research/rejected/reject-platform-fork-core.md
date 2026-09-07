# Reject — Copy platform-specific skill layouts into portable core

## Considered

Maintaining parallel copies under `.cursor/skills/`, `.claude/skills/`, `.codex/skills/` in addition to root `skills/`.

## Evidence

- Cursor compatibility loading makes duplication tempting (`cursor-agent-skills.md`)
- VoltAgent path table lists six+ locations (`voltagent-awesome-agent-skills.md`)
- Anti-pattern: platform-forked core (`anti-patterns.md`)

## Why rejected

Drift risk; violates portable-first rule; adapters should map one canonical tree.

## Decision

**REJECT** duplicated skill content per host.

## Alternative

Single `skills/` + adapter symlinks/generators (decision-002).
