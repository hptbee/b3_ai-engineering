# Activation results v2 (post-retune descriptions)

**Date:** 2026-09-07  
**Judge:** description + when-not-to-use on current `SKILL.md` files at `675bd41`.  
**Not:** Cursor skill-loader activation (`cursor-host-v2.md`).

v1 (`activation-results.md`) is the **pre-retune** record. This table is the second pass after F1–F5 description ADAPT.

Classifications: `CORRECT` | `MISSED` | `FALSE_POSITIVE` | `REDUNDANT` | `AMBIGUOUS`.

| ID | Expected | Description match | Class | Notes |
| --- | --- | --- | --- | --- |
| V1 | debugging | debugging; problem-solving excluded (“root-cause investigation before a patch”) | CORRECT | F1 retune held |
| V2 | planning | planning; problem-solving excluded (“plan-only requests”) | CORRECT | F1 retune held |
| V3 | refactoring | refactoring; problem-solving excluded (“structure-only refactors”) | CORRECT | v1 AMBIGUOUS resolved on wording |
| V4 | testing-strategy | testing-strategy; verification quiet (no pass claim) | CORRECT | |
| V5 | react-components | react-components; react-hooks excluded (“where state lives in the component tree”) | CORRECT | F2 retune held |
| V6 | react-hooks | react-hooks (`useEffect` / copied props) | CORRECT | |
| V7 | typescript-contracts | typescript-contracts; api-design excluded as primary for REST error/pagination | CORRECT | v1 AMBIGUOUS reduced |
| V8 | react-performance | react-performance; threejs-performance quiet | CORRECT | |
| V9 | accessibility | accessibility | CORRECT | |
| V10 | nodejs-runtime | nodejs-runtime | CORRECT | |
| V11 | nodejs-runtime | nodejs-runtime | CORRECT | |
| V12 | api-design | api-design; api-security quiet (no authz) | CORRECT | |
| V13 | api-security | api-security; api-design excludes object-level authz as primary | CORRECT | |
| V14 | csharp-async | csharp-async; ef-core excludes blocking `.Result` | CORRECT | |
| V15 | aspnet-core | aspnet-core; ef-core excludes DI lifetimes of `DbContext` | CORRECT | F3 retune held |
| V16 | api-design + aspnet-core | api-design (ProblemDetails in description); aspnet-core excludes error-contract design | CORRECT as **api-design primary** | Matrix still lists both; F4 *intended* aspnet-core to stay quiet. Not a loader test. |
| V17 | ef-core | ef-core | CORRECT | |
| V18 | not ef-core | ef-core description excludes Dapper/ADO.NET | CORRECT | F3 retune held |
| V19 | threejs-resources | threejs-resources; threejs-performance excludes dispose-only | CORRECT | |
| V20 | threejs-performance | threejs-performance | CORRECT | |
| V21 | react-three-fiber | react-three-fiber; react-hooks excludes `useFrame` | CORRECT | |
| V22 | react-performance | react-performance; threejs-performance quiet (FPS fine) | CORRECT | |
| V23 | nodejs-runtime | nodejs-runtime | CORRECT | |
| V24 | none / tiny | planning excluded (one-file fix); debugging excluded; problem-solving still possible | AMBIGUOUS | Tiny README typo has no dedicated skill; problem-solving may still fire |
| V25 | simplest-correct | simplest-correct; excludes local “shortest code” | CORRECT | F5 retune held |

## Counts (V1–V25, description judge only)

| Class | Count |
| --- | ---: |
| CORRECT | 24 |
| AMBIGUOUS | 1 (V24) |
| REDUNDANT | 0 |
| FALSE_POSITIVE | 0 |
| MISSED expected primary | 0 |

## What this proves

Post-retune **wording** no longer greedily matches V1, V2, V5, V15, V18 on paper.

## What this does not prove

Cursor will **not** apply these descriptions unless it loads the skills. Baseline host discovery in this workspace was **FAIL** (`cursor-host-v2.md`).
