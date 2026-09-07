# Validation matrix v1

Tasks are short, realistic prompts. Expected skill is the **primary** method. Secondary skills may be valid composition, not automatic failure.

| ID | Area | Prompt (minimal context) | Expected primary | Near-miss / must stay quiet |
| --- | --- | --- | --- | --- |
| V1 | Eng | CI fails: `TypeError: Cannot read property 'id' of undefined` in `orderService.ts` after yesterday’s merge. Cause unknown. | `debugging` | `planning` (not multi-file design); `verification` until a claim |
| V2 | Eng | Plan order CSV export across API, worker, and React admin. Do not write code yet. | `planning` | `problem-solving` must not start implement |
| V3 | Eng | Extract duplicate `formatDate` helpers; no behavior change. | `refactoring` | `react-performance` |
| V4 | Eng | Need a test for a one-line footer label change? | `testing-strategy` | `verification` (no claim tests passed) |
| V5 | React | Where should product-table filter state live? | `react-components` | `react-hooks` (tree placement ≠ effect deps) |
| V6 | React | `useEffect` copies `props.user` into state; form stale when user changes. | `react-hooks` | `react-performance` |
| V7 | TS | Fetch handler types the JSON body as `any`; runtime crash on missing `id`. | `typescript-contracts` | `verification` for “tsc passed” |
| V8 | React | Search box re-renders a 200-row table every keystroke. | `react-performance` | `threejs-performance` |
| V9 | A11y | Login fields use placeholder as the only label. | `accessibility` | `react-performance` |
| V10 | Node | Handler `JSON.parse`s a huge body on the request thread; event loop stalls. | `nodejs-runtime` | `react-performance` |
| V11 | Node | SIGTERM does not quit; Redis client stays open in Kubernetes. | `nodejs-runtime` | `api-design` |
| V12 | API | Design `GET /invoices` with pagination and one error JSON shape. No auth discussion. | `api-design` | `api-security` |
| V13 | Sec | `GET /orders/:id` returns another user’s order if you guess the UUID. | `api-security` | `api-design` as primary |
| V14 | C# | Controller uses `.GetAwaiter().GetResult()` on an EF query. | `csharp-async` | `ef-core` (not query shape) |
| V15 | ASP.NET | Singleton `CacheService` takes scoped `AppDbContext`. | `aspnet-core` | `ef-core` (lifetime, not LINQ) |
| V16 | API/.NET | Validation failures return ad-hoc JSON; want ProblemDetails. | `api-design` + `aspnet-core` | — composition |
| V17 | EF | List endpoint `Include`s entire `Customer` graph; SQL huge. | `ef-core` | `aspnet-core` |
| V18 | SQL | Report uses **Dapper** `QueryAsync`; `SELECT *` inside a loop. | none of `ef-core` | `ef-core` must stay quiet |
| V19 | Three | GPU memory grows each time we leave the product viewer. | `threejs-resources` | `threejs-performance` if dispose-only |
| V20 | Three | 5000 crate meshes → 5000 draw calls. | `threejs-performance` | `react-performance` |
| V21 | R3F | `useFrame` updates mesh rotation **and** `setState` for HUD degrees. | `react-three-fiber` | `react-hooks` (`useFrame` excluded) |
| V22 | Boundary | Item list **beside** `<Canvas>` re-renders; WebGL FPS is fine. | `react-performance` | `threejs-performance` |
| V23 | Near | Node p95 2s: sequential Redis `await`s in a loop. | `nodejs-runtime` | `react-performance` |
| V24 | Near | Fix a typo in README title. | none / `problem-solving` tiny | `planning`, `debugging` |
| V25 | Arch | Eight-person internal tool: five microservices + CQRS day one. | `simplest-correct` | must not forbid complexity if PCI/scale named |

## Composition scenarios

| ID | Stack | Prompt |
| --- | --- | --- |
| C1 | React feature | Build a settings form: tabs, typed PATCH DTO, labels, no extra effects. |
| C2 | ASP.NET API | New orders API: ProblemDetails, `[Authorize]`, per-id authz, cancel on request abort. |
| C3 | R3F | Canvas + GLTF, unmount without leak, `useFrame` animation, many identical trees. |

## Review-loop / agents / commands

| ID | Kind |
| --- | --- |
| R1 | Feature: add invoice list pagination (normal) |
| R2 | Security: BOLA on `GET /orders/:id` |
| R3 | Architecture: proposed event bus for 2-module app |
| R4 | Bug: stale React form from V6 |
| A1 | `security-reviewer` on R2 |
| A2 | `architecture-reviewer` on R3 |
| K1–K6 | Commands `plan` `implement` `debug` `review` `verify` `review-loop` |
