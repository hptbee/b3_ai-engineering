# Activation results v1

**Judge:** this agent, matching each prompt to skill `description` + when-not-to-use (trigger surface).  
**Not:** Cursor/Codex/Claude metadata loaders (`NOT VERIFIED`).

Classifications: `CORRECT` | `MISSED` | `FALSE_POSITIVE` | `REDUNDANT` | `AMBIGUOUS`.

A specialized skill plus a **broad** `problem-solving` hit is recorded as **REDUNDANT** when the task did not ask for the full implement loop.

| ID | Expected | Activated (description match) | Class | Notes |
| --- | --- | --- | --- | --- |
| V1 | debugging | debugging; **problem-solving** (“bug… unclear failure”) | REDUNDANT | Body already hands off to debugging; **description still greedy** |
| V2 | planning | planning; **problem-solving** (“feature”) | REDUNDANT | Prompt said do not code; problem-solving description does not say that |
| V3 | refactoring | refactoring; problem-solving possible | AMBIGUOUS | “software problem… change” vs refactoring “structure only” |
| V4 | testing-strategy | testing-strategy | CORRECT | verification correctly quiet (no pass claim) |
| V5 | react-components | react-components; **react-hooks** (`useState` in description) | FALSE_POSITIVE | hooks skill lists useState; tree placement is components |
| V6 | react-hooks | react-hooks | CORRECT | react-components stayed quieter (effect, not hierarchy) |
| V7 | typescript-contracts | typescript-contracts; api-design possible if “API JSON” | AMBIGUOUS | DTO vs REST contract; both descriptions mention API types |
| V8 | react-performance | react-performance | CORRECT | threejs-performance quiet |
| V9 | accessibility | accessibility | CORRECT | |
| V10 | nodejs-runtime | nodejs-runtime | CORRECT | react-performance quiet |
| V11 | nodejs-runtime | nodejs-runtime | CORRECT | |
| V12 | api-design | api-design | CORRECT | api-security quiet (no authz words) |
| V13 | api-security | api-security | CORRECT | api-design not primary |
| V14 | csharp-async | csharp-async | CORRECT | ef-core correctly quiet (blocking, not SQL shape) |
| V15 | aspnet-core | aspnet-core; **ef-core** (`DbContext` + “reviewing EF”) | FALSE_POSITIVE | Lifetime bug is DI, not LINQ |
| V16 | api-design + aspnet-core | both | REDUNDANT | ProblemDetails in **both** descriptions — composition tax |
| V17 | ef-core | ef-core | CORRECT | |
| V18 | not ef-core | **ef-core** (“Slow SQL” in when-to-use) vs “Do not use for Dapper-only” | AMBIGUOUS → treat as **FALSE_POSITIVE risk** | Description fights itself: slow SQL vs Dapper exclusion |
| V19 | threejs-resources | threejs-resources | CORRECT | performance skill says not dispose-only |
| V20 | threejs-performance | threejs-performance | CORRECT | |
| V21 | react-three-fiber | react-three-fiber | CORRECT | react-hooks excludes useFrame |
| V22 | react-performance | react-performance | CORRECT | threejs-performance quiet (FPS fine) |
| V23 | nodejs-runtime | nodejs-runtime | CORRECT | react-performance quiet |
| V24 | none/tiny | **planning** should miss; **debugging** should miss; problem-solving may still fire | AMBIGUOUS | Tiny change vs “end to end” |
| V25 | simplest-correct | simplest-correct | CORRECT | |

## Command files (K1–K6)

Read as selectors only. **None** duplicate skill procedures. **CORRECT** as thin orchestrators.

| Command | Selects | Duplicate skill body? |
| --- | --- | --- |
| plan | planning (+ simplest-correct if shape) | No |
| implement | problem-solving + smallest domain | No |
| debug | debugging then verification | No |
| review | code-review | No |
| verify | verification + rule | No |
| review-loop | docs/review-loop + agents | No (runtime still unspecified) |

## Agent activation (conceptual)

No host `Agent` tool was invoked. Mandates are clear on paper. **Invocation: NOT VERIFIED.**

## Counts (primary-task set V1–V25)

| Class | Count (approx) |
| --- | --- |
| CORRECT | 16 |
| REDUNDANT | 3 (V1, V2, V16) |
| FALSE_POSITIVE / FP risk | 3 (V5 hooks, V15 ef-core, V18 Dapper) |
| AMBIGUOUS | 3 (V3, V7, V24) |
| MISSED | 0 on expected primaries (when the expected skill’s description matched) |

**No MISSED primary** in this description-judge pass. Failures are **overlap and false positives**, not silence.

After this record, descriptions were **ADAPT**ed (F1–F5). This table is the **pre-change** evidence, not a second run.
