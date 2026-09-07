---
name: simplest-correct
description: >
  Use when choosing architecture: layers, Clean/Hexagonal/DDD/CQRS,
  microservices vs modular monolith. Use when someone proposes more
  abstraction than the requirements justify. Do not use for a localized
  bugfix or for implementing a framework tutorial.
---

# Simplest correct architecture

```text
simplest solution that meets real requirements
        >
unnecessary abstraction
```

Complexity needs a named requirement (scale, team boundary, consistency, compliance).

## When to use

- Greenfield service shape
- “Should we add a domain layer / mediator / event bus?”
- Review of over-architecture

## When not to use

- The product repo already chose an architecture — follow it (`docs/precedence.md`)
- Performance incident with measurements → performance skills

## Procedure

1. **List actual requirements** (users, consistency, deploy units, team ownership).
2. **Default:** modular monolith, explicit modules, one deploy unit.
3. **Add a layer** only to protect a real boundary (e.g. EF not leaking into API).
4. **DDD/CQRS/events/microservices:** allow when requirements match (multiple writers, independent scale, separate failure domains) — not as prestige.
5. **Record the tradeoff** if skipping a richer pattern.

Personal taste (Clean Architecture everywhere) never beats project requirements or this principle as a strong guideline.

## Verification

The chosen shape can be explained in five sentences and maps to requirements. If not, INCOMPLETE design.

## Provenance

User-stated B3 principle. Tiki “ponytail / karpathy” anti-over-engineering observed. Not a copy of those rule files.
