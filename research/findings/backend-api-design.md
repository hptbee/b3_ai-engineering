# Backend — API design and security

## Observation

API security review improves when findings use **OWASP API Top 10 2023** categories — especially authorization at object and property level, not only authentication.

## Evidence

- `research/sources/owasp-api-security-top10.md`
- b3 `code-review` security dimension (generic today)

## Pattern

```text
API change review:
1. Inventory endpoints touched (method, path, auth requirement)
2. For each ID in path/body: verify object-level authz (API1)
3. For each response field: verify property-level authz (API3)
4. Check function-level roles for admin paths (API5)
5. Rate limits / pagination for list and expensive ops (API4)
6. SSRF on outbound fetches (API7)
7. Map findings → APIx:2023 + evidence (request/response repro)
```

## Why it matters

Agents often review authn (logged in?) but miss BOLA/BFLA and mass assignment. OWASP gives shared IDs for review-loop findings.

## Trade-offs

- REST-centric examples; GraphQL needs field-level authz emphasis (API3 still applies)
- Business flow abuse (API6) requires domain context — mark speculative until understood
- Not a substitute for OpenAPI contract testing

## Potential application

Future skill `backend-api-security`:
- Procedure above + `references/owasp-api-top10-links.md`
- Trigger: "review this API", "is this endpoint secure", "REST authz"
- Near-miss: frontend component work, Node process hardening only

## Confidence

High for taxonomy; Medium for optimal procedure length
