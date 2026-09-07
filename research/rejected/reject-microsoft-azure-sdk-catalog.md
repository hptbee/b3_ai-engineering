# Reject — Microsoft Azure SDK skill catalog

## Considered

Import microsoft/skills `.github/plugins/azure-sdk-dotnet` (~29 `*-dotnet` skills) as B3 C#/.NET coverage.

## Evidence

- microsoft/skills README (fetched 2026-09-07): Azure ARM, Event Hubs, Key Vault, OpenAI, etc.
- User stack: C#, ASP.NET Core, EF Core, Azure as **context** — not Azure SDK encyclopedia

## Why rejected

- Skills are product SDK how-tos, version-sensitive, huge
- Do not teach async, DI, middleware, EF query shape, or simplest architecture
- Host plugin layout (`.github/skills`) is not portable core

## Decision

**REJECT** bulk import.

## Alternative

B3 `csharp-async`, `aspnet-core`, `ef-core` skills from established language/framework practice; Azure remains project-specific or future thin skill if a real task needs it.
