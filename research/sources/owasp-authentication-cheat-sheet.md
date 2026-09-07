# OWASP Authentication Cheat Sheet

## Source

https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html

## Tier

Tier 1

## Purpose

Practical authentication security controls: sessions, passwords, MFA, federation, common failures.

## Architecture

- Cheat sheet series format: actionable bullets with rationale
- Covers credential storage, session management, password policies, recovery, MFA, SSO/federation pointers
- Cross-links other sheets (Session Management, Forgot Password, etc.)

## Important Patterns

- Prefer **standard protocols** (OAuth 2.0 / OIDC) over custom auth
- **Fail securely** — generic errors, no user enumeration
- **Session fixation** prevention, secure cookie flags (`HttpOnly`, `Secure`, `SameSite`)
- **MFA** for sensitive operations
- Rate limiting and lockout policies with care (avoid DoS via lockout)
- Centralize auth logic; avoid scattered checks

## Skill Design

Auth guidance splits across:
- **Design** (choose OIDC, session vs JWT trade-offs) — architecture skill
- **Review** (cheat sheet checklist) — security review skill
- **Implementation** — product-specific, not portable core

Agent skill should cite cheat sheet sections when flagging auth issues — not reproduce entire sheet.

## Rules / Instructions

Hard rules possible: no plaintext passwords, require HTTPS, httpOnly session cookies — user promotes via rules after decision.

## Agents

N/A

## Commands / Workflows

N/A

## Evaluation

Checklist-driven review; verification = reproduce auth flow tests, inspect cookie flags, token expiry behavior.

## Portability

Protocol-level guidance portable; framework middleware differs (Express, Fastify, Next.js auth).

## Strengths

- Actionable, widely cited
- Complements API Top 10 API2 (Broken Authentication)

## Weaknesses / Trade-offs

- Not a substitute for OIDC/OAuth spec details when implementing providers
- JWT guidance requires pairing with token storage sheets to avoid footguns

## Interesting Implementation Details

- Warns against exposing auth success/failure differences enabling enumeration

## Relevant Files

- OWASP Session Management Cheat Sheet (companion)
- OAuth 2.0 / OIDC specs for implementation depth (future source)

## Evidence

- Fetched 2026-09-07: authentication controls, session guidance, federation references

## Relevance to b3-ai-engineering

Future `backend-auth-security` skill checklist; links API2 findings to concrete controls.

## Initial Recommendation

ADOPT (checklist basis); ADAPT (condensed procedure + references)
