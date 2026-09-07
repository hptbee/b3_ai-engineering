# Reject — Auto-promote lessons to rules

## Considered

Automatically converting review lessons or incident notes into new hard rules.

## Evidence

- b3 lifecycle already rejects this (`docs/system-lifecycle.md` — internal)
- External systems rarely document auto-promotion; Superpowers hook enforcement shows risk of hardening workflows without eval (`obra-superpowers.md`)
- Anthropic: add complexity only when measured (`anthropic-building-effective-agents.md`)

## Why rejected

Single-incident rules accumulate noise; preferences masquerade as constraints.

## Decision

**REJECT** automatic lesson→rule promotion.

## Alternative

Lesson → candidate → eval → human approval → rule/skill/knowledge (b3 lifecycle).
