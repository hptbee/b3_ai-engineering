---
name: nodejs-runtime
description: >
  Use when building or reviewing Node.js services: async, event loop,
  streams, concurrency, shutdown, errors, logging, blocking work. Do not
  use for browser React, C# / ASP.NET, or API authz taxonomies alone.
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
2. **Event loop:** no sync CPU on the request path; use `worker_threads`/offload. No giant JSON parse on the hot path without care.
3. **HTTP:** timeouts (`headersTimeout`, `requestTimeout`, `keepAliveTimeout`); socket `error` handlers; reverse proxy in production.
4. **Shutdown:** listen SIGTERM; stop accepting; drain; close DB/redis; timeout then exit.
5. **Config:** fail fast on missing secrets; never commit credentials.
6. **Errors:** distinguish operational vs programmer errors; don’t leak stacks to clients.
7. **Streams:** respect backpressure (`pipe`/`pipeline`); don’t buffer entire uploads.

See `references/threats.md` for Node security threat index.

## Verification

Reproduce hang/leak or run a smoke under load if possible. Otherwise INCOMPLETE. `npm audit` is supply-chain evidence, not runtime proof.

## Failure handling

- Permission model `--permission` is experimental — do not require it
- Missing infra (proxy) — record assumption

## Provenance

ADAPT Node.js security best practices (`research/sources/nodejs-security-best-practices.md`).
