---
name: aspnet-core
description: >
  Use when building ASP.NET Core apps: DI, middleware order, Options,
  logging, authn/z, validation, ProblemDetails, background services,
  caching. Do not use for raw C# Task mechanics or EF Core query
  performance.
---

# ASP.NET Core

Pipeline and hosting. Keep middleware order honest. Authz is not optional.

## When to use

- Web API / MVC, minimal APIs
- DI lifetimes, IHostedService
- JWT/cookie auth configuration

## When not to use

- `async` deadlocks in a class library → `csharp-async`
- N+1 queries → `ef-core`
- Generic REST taxonomy → `api-design` / `api-security`

## Procedure

1. **DI:** Singleton must be thread-safe; don’t inject scoped into singleton. Prefer `IHttpClientFactory`.
2. **Middleware:** exception → HTTPS → authn → authz → endpoints. Don’t invent a second pipeline.
3. **Options:** `IOptions`/`IOptionsMonitor`; validate on start (`ValidateOnStart`).
4. **Authz:** `[Authorize]` / policies on every sensitive endpoint; default deny.
5. **Validation:** DataAnnotations or FluentValidation at the boundary; return `ValidationProblem`.
6. **Errors:** `ProblemDetails` (RFC 7807); no stack traces in production.
7. **BackgroundService:** honor `StoppingToken`; don’t `while(true)` without delay/cancel.
8. **Observability:** structured logging; correlation id; don’t log secrets/tokens.

## Verification

Hit unauthorized route (401/403), validation fail (400), happy path. INCOMPLETE if app won’t run.

## Failure handling

- Minimal APIs vs controllers — follow the repo
- Azure hosting specifics — project requirements, not this skill

## Provenance

ASP.NET Core official patterns. Combined with `api-security` for BOLA (filters don’t replace per-id checks).
