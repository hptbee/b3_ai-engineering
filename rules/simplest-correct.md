---
type: rule
strength: strong
scope: architecture
source: synthesized
authority: high
---

# Simplest correct solution

Strong guideline: prefer the **simplest architecture that meets stated requirements** over extra layers, buses, or service splits.

Do not introduce Clean Architecture, CQRS, microservices, or a mediator solely because they are fashionable.

Skip this guideline only with a **named requirement** (scale, team boundary, consistency, compliance) recorded in the working notes.

Method: `skills/architecture/simplest-correct/SKILL.md`.

Hard rules (verification honesty, safety) still win (`docs/precedence.md`).
