# Decision 007 — Backend skills approach

## Context

Track B researched Node.js, API security, authentication, and security-focused review skills for future domain synthesis.

## Options Considered

1. Import Trail of Bits `differential-review` plugin wholesale
2. Expand `code-review` only — no backend specialist skills
3. **Layered model**: general code-review + focused backend security/architecture skills
4. Single `backend` monolith skill

## Evidence

- Sources: `owasp-api-security-top10.md`, `owasp-authentication-cheat-sheet.md`, `nodejs-security-best-practices.md`, `trailofbits-differential-review.md`
- Findings: `backend-api-design.md`, `backend-auth-security.md`, `backend-node-architecture.md`
- Comparison: `backend-skills-comparison.md`
- Decisions: `decision-004-review-loop.md`, `decision-006-frontend-skills.md` (parallel split pattern)

## Decision

**ADAPT** layered backend skills (synthesis phase — not implemented in this track):

| Skill (planned) | Basis | Decision |
| --- | --- | --- |
| API security review | OWASP API Top 10 2023 | **ADOPT** taxonomy + procedure |
| Auth/session security | OWASP Auth Cheat Sheet | **ADAPT** checklist |
| Node architecture + runtime | Node security best practices | **ADAPT** baseline + references |
| Security differential review | Trail of Bits structure | **ADAPT** triage + rationalizations + report artifact; **REJECT** full 6-phase default |

**REJECT:**
- Copying Trail of Bits plugin tree or subagent names into portable core
- Monolithic backend skill
- Replacing `code-review` with security-only workflow

## Rationale

OWASP provides citeable finding vocabulary; Node doc covers runtime gaps API Top 10 misses; Trail of Bits teaches **honest depth scaling** and anti-rationalizations without requiring enterprise time budgets.

## Consequences

- Synthesis creates `skills/backend/` (or similar) with trigger fixtures
- `allowed-tools` and subagent dispatch documented in adapters only
- High-risk changes may optionally invoke adapted differential review — aligns with decision-004 optional reconstruction

## Confidence

Medium-High
