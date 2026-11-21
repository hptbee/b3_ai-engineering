---
name: nodejs-runtime
description: >
  Use when building or reviewing Node.js services: async, event loop,
  streams, concurrency, shutdown, errors, logging, blocking or CPU-bound
  work, memory growth, hot-path serialization. Do not use for browser
  React, C# / ASP.NET, API authz taxonomies, or micro-optimizing cold
  paths with no stall or leak.
---

# Node.js runtime

Do not block the event loop. Own resource lifecycle. Fail explicitly.

## When to use

- Express/Fastify/HTTP servers, workers, CLIs in Node
- Hangs, memory growth, unhandledRejection
- Timeouts, graceful shutdown, CPU-heavy work

## When not to use

- REST BOLA/authz catalog → `api-security`
- ASP.NET → `aspnet-core`
- Frontend TS types → `typescript-contracts`

## Procedure

1. **Async:** never swallow promises; `unhandledRejection` is a defect. Bound concurrency (queues), don’t `Promise.all` unbounded lists.
2. **Event loop:** no sync CPU on the request path; use `worker_threads`/offload. No giant JSON parse/stringify on the hot path without care.
3. **I/O:** don’t `await` independent calls in a loop (waterfall); batch or pipeline; respect stream backpressure (`pipe`/`pipeline`); don’t buffer entire uploads.
4. **Memory:** unbounded arrays/maps, listeners, and buffers are leak suspects; heap snapshot / `clinic` only if tools exist — else INCOMPLETE.
5. **HTTP:** timeouts (`headersTimeout`, `requestTimeout`, `keepAliveTimeout`); socket `error` handlers; reverse proxy in production.
6. **Shutdown:** listen SIGTERM; stop accepting; drain; close DB/redis; timeout then exit.
7. **Config:** fail fast on missing secrets; never commit credentials.
8. **Errors:** distinguish operational vs programmer errors; don’t leak stacks to clients.

Do not add a cache or worker pool because a list of ten items “might grow”.

See `references/threats.md` for Node security threat index.

## Verification

Reproduce hang/leak or run a smoke under load if possible. Otherwise INCOMPLETE. `npm audit` is supply-chain evidence, not runtime proof.

## Failure handling

- Permission model `--permission` is experimental — do not require it
- Missing infra (proxy) — record assumption

## Provenance

ADAPT Node.js security best practices (`research/sources/nodejs-security-best-practices.md`).
