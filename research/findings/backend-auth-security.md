# Backend — Authentication and session security

## Observation

Authentication failures cluster around **session handling**, **credential storage**, and **user enumeration** — OWASP cheat sheet gives concrete controls agents can verify.

## Evidence

- `research/sources/owasp-authentication-cheat-sheet.md`
- API Top 10 API2 (`owasp-api-security-top10.md`)

## Pattern

| Area | Control |
| --- | --- |
| Passwords | Length/blocklist, no composition rules, bcrypt/argon2 storage |
| Sessions | Random session IDs, rotation on login, secure cookie flags |
| Errors | Generic auth failure messages (no enumeration) |
| MFA | Required for sensitive accounts/operations |
| Federation | Prefer OIDC/OAuth over custom token schemes |
| Service accounts | No shared creds between front-end and internal admin paths |

## Why it matters

Agents recommend JWT-in-localStorage or custom auth frequently. Checklist ties to verification evidence (inspect Set-Cookie, test lockout, review token expiry).

## Trade-offs

- JWT vs session debate context-dependent — skill should ask requirements, not mandate one stack
- OAuth/OIDC depth needs separate source pass for implementation skills
- Rate limiting vs account lockout DoS trade-off requires judgment

## Potential application

Future skill `backend-auth-security`:
- Checklist mapped to cheat sheet sections
- Cross-link API2 for API token auth
- Verification steps explicit (cookie flags, refresh rotation, logout invalidates server session)

## Confidence

High
