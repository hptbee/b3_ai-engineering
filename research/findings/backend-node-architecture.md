# Backend — Node.js architecture and runtime security

## Observation

Node backend safety splits into **runtime/process threats** (DoS, prototype pollution, dependencies) and **application/API layers** (OWASP). Official Node security doc defines application responsibility boundaries clearly.

## Evidence

- `research/sources/nodejs-security-best-practices.md`
- Trail of Bits differential review (`trailofbits-differential-review.md`) for change-focused security depth

## Pattern

```text
Node service baseline:
1. HTTP server: error handlers, timeouts (headersTimeout, requestTimeout, keepAliveTimeout)
2. Reverse proxy / rate limits at edge where possible
3. Dependency hygiene: lockfile, audit, minimal packages
4. Input validation at trust boundaries (schema validation, safe merge)
5. Avoid --inspect on exposed interfaces; understand DNS rebinding
6. Prototype pollution guards on object merge/deserialize
7. Secrets: env vars, not committed; constant-time compare for tokens
```

For **diff review** of Node changes, ADAPT Trail of Bits triage:
- Classify HIGH/MEDIUM/LOW risk
- Git blame removed validation/auth code
- Flag missing tests on modified security paths

## Why it matters

Many Node vulnerabilities are **misconfiguration and missing handlers**, not exotic CVEs. Agents skip timeout configuration and error handlers when generating Express/Fastify servers.

## Trade-offs

- Permission model still experimental — note INCOMPLETE rather than mandate
- Infra mitigations (WAF, proxy) may be outside repo scope — record assumption
- Full differential-review pipeline too heavy for default personal loop

## Potential application

- `backend-node-architecture` skill: baseline + project layout (routes, middleware, config)
- Security depth: ADAPT rationalizations table into `backend-security-review` or extend `code-review` with optional deep mode
- References: Node threat slices, not full doc paste

## Confidence

Medium-High
