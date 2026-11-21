---
name: csharp-async
description: >
  Use when writing or reviewing C# concurrency: async/await, Task,
  CancellationToken, IDisposable, NRT, exceptions, allocations on hot
  paths, channels. Do not use for ASP.NET middleware/DI catalogs, EF
  query shape, or Span/pooling rewrites on cold code with no measurement.
---

# C# async and language practice

Async all the way. Honor cancellation. Dispose what you own.

## When to use

- `async Task` services, libraries, workers
- Deadlocks (`Result`/`Wait` on async)
- Memory / `IDisposable` leaks

## When not to use

- Controllers, middleware, Options → `aspnet-core`
- LINQ-to-Entities / tracking → `ef-core`
- Rewrite to `Span<T>` / object pooling on a cold admin path with no benchmark → do not

## Procedure

1. **Async:** `async Task` / `ValueTask` as appropriate; never `async void` except event handlers. Don’t block (`GetAwaiter().GetResult()`).
2. **Cancellation:** pass `CancellationToken` through I/O; link tokens in composed operations.
3. **NRT:** enable nullable; don’t `!` to silence. Prefer `ArgumentNullException.ThrowIfNull`.
4. **Exceptions:** don’t catch-all and swallow; use specific types; don’t use exceptions for expected control flow on hot paths.
5. **IDisposable / IAsyncDisposable:** `using`; don’t dispose what you don’t own (HttpClient factory vs per-request new).
6. **Allocations / GC:** on **hot** paths, avoid per-call `ToList`/boxing/large closures; collections sized for the workload. Cold admin code: leave it.
7. **Concurrency:** `lock` vs `SemaphoreSlim` vs channels — pick one model; document shared state.
8. **Claims of faster:** BenchmarkDotNet / `dotnet-trace` / counters if present; otherwise INCOMPLETE — do not rewrite to `Span<T>` on a guess.

## Verification

Cancel a request and show work stops, or a unit test with `CancellationToken`. Perf claims need before/after or INCOMPLETE.

## Failure handling

- Old-style `Begin/End` — follow existing code or isolate
- Unity/game loop — out of scope

## Provenance

Established .NET practice (BCL). Microsoft Azure SDK skills **rejected** as catalog. Personal stack: Tùng — still project repo wins.
