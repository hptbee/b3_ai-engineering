---
name: typescript-contracts
description: >
  Use when designing or fixing TypeScript types: narrowing, unions,
  generics, unknown vs any, assertions, nullability, API DTO vs domain
  types, runtime validation at boundaries. Do not use for React component
  layout or for running tsc as a ship claim (verification).
---

# TypeScript contracts

Useful correctness. Not maximum type-level cleverness.

## When to use

- API types, DTOs, form values
- `any`, unsafe `as`, extra `!`
- Discriminated unions, exhaustive switches
- Zod/schema vs types drifting

## When not to use

- “Make the UI” → `react-components`
- “Did it typecheck?” as success → `verification` (run `tsc`)

## Procedure

1. **Model variants as discriminated unions**, not optional fields that lie (`status` + unrelated payload).
2. **`unknown` at boundaries** (JSON, `error` in catch); narrow before use. Avoid `any`.
3. **Assertions (`as`, `!`)** only when you can name why the compiler is wrong — and prefer a type guard.
4. **Input vs output types** (create DTO ≠ entity with server ids).
5. **Runtime validate at trust boundaries** (HTTP body, env, third-party JSON). Do not re-validate every internal call.
6. **Generics** for reuse with constraints; stop when the type is harder than the runtime.
7. **Nullability:** explicit `T | null`; don’t silence with `any`.

## Verification

`tsc --noEmit` (or project script) plus a test that invalid payload is rejected, or INCOMPLETE.

## Failure handling

- `strict` off in project → do not secretly fight the repo; note the gap
- Over-branded IDs — use if they prevent real bugs; skip as fashion

## Provenance

ADAPT TypeScript Handbook + Tiki interface skill (boundary validation, unions). decision-006: no standalone TS skill unless triggers needed — triggers are distinct here.
