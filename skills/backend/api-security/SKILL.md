---
name: api-security
description: >
  Use when reviewing or implementing API authentication and authorization:
  object-level authz, property-level authz, function-level roles, tokens,
  sessions, mass assignment, SSRF, rate limits. Do not use for generic
  Node process hardening or UI accessibility.
---

# API security

Map findings to OWASP API Top 10 2023 ids when claiming defects.

## When to use

- Endpoint authn/z, IDOR/BOLA, admin vs user routes
- JWT/session cookies, MFA-sensitive flows
- Outbound fetch of user URLs

## When not to use

- Event-loop / shutdown → `nodejs-runtime`
- API pagination/error shape only → `api-design`
- Independent full loop → `docs/review-loop.md` + `agents/security-reviewer.md`

## Procedure

1. Inventory endpoints (method, auth requirement, resource id).
2. **API1 BOLA:** every id from the client is authorized as *this user’s* object.
3. **API3:** response/write fields not mass-assigned; no extra properties leaked.
4. **API5:** admin functions not reachable with user tokens.
5. **API2:** token/session issues — httpOnly/Secure/SameSite, rotation, no user enumeration (OWASP Auth cheat sheet).
6. **API4:** rate limit expensive operations; pagination.
7. **API7:** SSRF — allowlist outbound URLs.
8. Record findings with evidence (request/response). Severity ≠ confidence.

Rationalizations (ADAPT Trail of Bits): “small PR” and “just a refactor” do not skip authz.

## Verification

Repro unauthorized access attempt, or INCOMPLETE. Cookie flags inspected if session auth.

## Failure handling

- No running server → static review, INCOMPLETE for dynamic authz
- Business-flow abuse (API6) needs domain context — SPECULATIVE until understood

## Provenance

ADOPT OWASP API Top 10 taxonomy. ADAPT auth cheat sheet + Trail of Bits risk-first triage (not 6-phase plugin).
