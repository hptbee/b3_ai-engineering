---
name: api-design
description: >
  Use when designing HTTP/REST (or similar) APIs: contracts, errors,
  pagination, chatty list+detail round-trips, compatibility, validation
  at boundaries, ProblemDetails. Do not use for object-level authorization,
  Node event-loop tuning, EF SQL N+1, UI component APIs, or adding a cache
  with no latency requirement.
---

# API design

Contract first. Validate at the edge. Prefer additive change.

## When to use

- New endpoints, DTOs, public module interfaces
- Error shape, pagination, versioning
- Frontend/backend type contracts

## When not to use

- “Is this BOLA-safe?” → `api-security`
- Event-loop / JSON parse stalls → `nodejs-runtime`
- EF N+1 SQL → `ef-core`
- React props composition → `react-components`
- “Add Redis for scale” on a 20-row admin list with no latency evidence → do not

## Procedure

1. **Define input/output types** before handlers (OpenAPI, TS, or C# records).
2. **One error shape** (Node: structured JSON; ASP.NET: `ProblemDetails`). Map 400/401/403/404/409/422/500 consistently.
3. **Validate untrusted input** at the boundary (body, query, third-party JSON). Internal code trusts parsed types.
4. **Lists paginate.** Don’t return unbounded collections.
5. **Chatty I/O:** don’t require N+1 HTTP round-trips for a list+details screen if one resource (or a bounded expand) can carry it. Caching/CDN is a **named** latency requirement — not a default Redis.
6. **Additive evolution:** optional new fields; don’t change types in place.
7. **Ids in URLs** are still authorization problems — design does not replace `api-security`.
8. **Idempotency** for unsafe retries where the product needs it (payments, at-least-once consumers).

## Verification

Contract tests or example requests/responses. Breaking change without migration note is FAIL.

## Failure handling

- GraphQL/gRPC: same principles; don’t force REST URL style
- Existing inconsistent API — don’t silently rewrite all errors unless scoped

## Provenance

ADAPT tikivn api-and-interface-design (Hyrum, boundaries, pagination). ASP.NET ProblemDetails for Tùng’s stack. Not copied verbatim.
