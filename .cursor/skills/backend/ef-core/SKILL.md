---
name: ef-core
description: >
  Use when writing or reviewing EF Core LINQ-to-Entities: tracking,
  projections, Include/N+1, round trips, list pagination, transactions,
  concurrency tokens, migrations. Do not use for Dapper or ADO.NET SQL,
  DI lifetimes of DbContext (aspnet-core), blocking .Result (csharp-async),
  API authz, or adding indexes with no slow-query evidence.
---

# EF Core

Query what you need. Tracking is a cost. N+1 is a defect on list endpoints.

## When to use

- LINQ to Entities, SaveChanges, migrations
- Slow **EF** SQL, cartesian explosions, identity resolution surprises

## When not to use

- Hand-written SQL / Dapper → product patterns; this skill only if mixing with EF
- API BOLA → `api-security` (still filter by tenant in queries)

## Procedure

1. **Projection:** `.Select` to DTO for reads; don’t materialize full graphs for lists.
2. **Tracking:** `AsNoTracking()` for read-only. Don’t mix tracked graphs carelessly.
3. **N+1 / round trips:** no `foreach` + extra query; `Include` only what you need or explicit join/projection.
4. **Lists:** `Skip`/`Take` (or keyset) on list endpoints; unbounded `ToListAsync` of a table is a defect.
5. **Indexes:** only with a slow query or plan evidence (`ToQueryString`, logging, actual plan). Do not sprinkle covering indexes “just in case”.
6. **Filters:** global query filters for tenancy; still authorize in the application.
7. **Transactions:** explicit for multi-SaveChanges; don’t hide distributed transactions by accident.
8. **Concurrency:** rowversion / `IsConcurrencyToken` where lost updates matter.
9. **Migrations:** expand/contract; don’t drop columns in the same release that old app instances need.

## Verification

Log SQL (`ToQueryString` or logging) for the list endpoint; show one query not N. Otherwise INCOMPLETE.

## Failure handling

- In-memory provider tests ≠ SQL Server behavior — say so
- Lazy loading enabled — treat as N+1 risk

## Provenance

EF Core docs (query performance). Tùng uses EF + Dapper — Dapper paths follow the product repo.
