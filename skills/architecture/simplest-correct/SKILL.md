---
name: simplest-correct
description: Use when choosing system architecture (layers, Clean/DDD/CQRS, microservices vs monolith, buses/frameworks); complexity needs a named requirement. Not for one-line bugfixes or local coding style.
---

# Simplest correct architecture

```text
simplest solution that meets real requirements
        >
unnecessary abstraction
```

This skill is **not** “always choose the simplest implementation.”
Local smallest-change is `rules/engineering-principles.md`.
This skill is **system shape**: extra services, layers, and patterns need a **named requirement** (scale, team boundary, consistency, compliance). Justified complexity is in bounds.

## When to use

- Greenfield service shape
- “Should we add a domain layer / mediator / event bus?”
- Review of over-architecture

## When not to use

- The product repo already chose an architecture — follow it (`docs/precedence.md`)
- Performance incident with measurements → performance skills

## Procedure

1. **List actual requirements** (users, consistency, deploy units, team ownership).
2. **Pre-implementation proportionality check** (before designing new components or subsystems):
   - Can existing code, native platform features, or the standard library solve this?
   - Is the proposed component actually necessary, or can a simpler representation/workflow (e.g., plain Markdown/config file over a custom parser or config framework) satisfy the requirement?
   - Are we building a reusable subsystem for a one-off convenience feature?
   - Is every added layer or abstraction justified by a concrete requirement?
   - Prefer reusing existing components, standard libraries, simple config files, direct workflows, and existing patterns over speculative abstractions.
3. **Default:** modular monolith, explicit modules, one deploy unit.
4. **Add a layer or subsystem** only to protect a real boundary (e.g. EF not leaking into API) or meet a concrete requirement (security, correctness, portability, explicit requirements, verified performance constraints — these take precedence over simplicity).
5. **DDD/CQRS/events/microservices:** allow when requirements match (multiple writers, independent scale, separate failure domains) — not as prestige.
6. **Record the tradeoff** if skipping a richer pattern.

Personal taste (Clean Architecture everywhere) never beats project requirements or this principle as a strong guideline.

## Verification

The chosen shape can be explained in five sentences and maps to requirements. If not, INCOMPLETE design.

## Failure handling

- Requirements, scale targets, or team/compliance boundaries are unstated → surface the missing inputs and mark the design `UNKNOWN / INCOMPLETE` instead of guessing extra layers.
- The product repo already enforces an architecture → follow repo conventions (`docs/precedence.md`); do not force a rewrite.
- Evidence is partial (e.g., unmeasured throughput/latency claims) → record the assumption explicitly and defer complexity until measured.
- The problem is a measured runtime bottleneck or local code-style fix → hand off to performance skills or `problem-solving` rather than stretching this skill.

## Provenance

User-stated B3 principle. Tiki “ponytail / karpathy” anti-over-engineering observed. Not a copy of those rule files.
