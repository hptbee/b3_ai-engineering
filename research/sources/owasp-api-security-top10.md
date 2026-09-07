# OWASP API Security Top 10 (2023)

## Source

https://owasp.org/www-project-api-security/

## Tier

Tier 1

## Purpose

Authoritative API threat taxonomy for design and review of HTTP/GraphQL/gRPC-style APIs.

## Architecture

- **API Top 10 2023** replaces 2019 edition with merged/refined categories
- Risk categories span authorization, authn, data exposure, resource consumption, SSRF, misconfiguration, inventory, third-party trust

## Important Patterns (2023)

| ID | Risk | Agent review hook |
| --- | --- | --- |
| API1 | Broken Object Level Authorization | Every ID-based access must authorize object owner |
| API2 | Broken Authentication | Token/session implementation flaws |
| API3 | Broken Object Property Level Authorization | Field-level authz; mass assignment |
| API4 | Unrestricted Resource Consumption | Rate limits, pagination, cost controls |
| API5 | Broken Function Level Authorization | Admin vs user function separation |
| API6 | Unrestricted Sensitive Business Flows | Abuse of workflows (bots, automation) |
| API7 | Server Side Request Forgery | Validate outbound fetch URLs |
| API8 | Security Misconfiguration | Defaults, verbose errors, CORS |
| API9 | Improper Inventory Management | Shadow/deprecated/debug endpoints |
| API10 | Unsafe Consumption of APIs | Trust boundaries for third-party data |

## Skill Design

API security skill should map findings to **APIx:2023** IDs when claiming defects — parallel to WCAG IDs for frontend.

Structure: review procedure + references to Top 10 detail pages — not paste full OWASP text.

## Rules / Instructions

Hard rules for production APIs may adopt specific Top 10 checks (e.g. always authorize BOLA) — promote via decision, not research alone.

## Agents

N/A — standard document.

## Commands / Workflows

N/A

## Evaluation

OWASP crAPI intentionally vulnerable API for training — future capability fixture candidate (deferred).

## Portability

API patterns portable across Node, Go, etc. Examples often HTTP/REST-centric.

## Strengths

- Industry-standard vocabulary for API reviews
- 2023 refresh addresses property-level authz and business flow abuse

## Weaknesses / Trade-offs

- Not implementation guide for specific frameworks
- GraphQL-specific guidance partially in separate cheat sheets
- Does not replace secure coding for Node runtime threats

## Interesting Implementation Details

- Combines 2019 excessive exposure + mass assignment into API3
- API6 emphasizes business logic abuse without implementation bugs

## Relevant Files

- owasp.org/API-Security/editions/2023/en/

## Evidence

- Fetched 2026-09-07: project page listing API1–API10 2023 summaries

## Relevance to b3-ai-engineering

Foundation for future `backend-api-security` review skill; complements generic `code-review` security dimension.

## Initial Recommendation

ADOPT (taxonomy for findings); ADAPT (procedure skill + links)
