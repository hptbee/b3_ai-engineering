# Composition results v1

Method: load listed SKILL.md files together and check procedure overlap on the composition prompt. No host multi-skill loader **NOT VERIFIED**.

## C1 — React settings form

Skills: `react-components` + `react-hooks` + `typescript-contracts` + `accessibility`

| Check | Result |
| --- | --- |
| Duplication | Low. Components: tree/state ownership. Hooks: no copy-props effect. TS: PATCH DTO vs entity. A11y: labels/focus. |
| Contradiction | None found. Hooks “derive in render” agrees with components “don’t duplicate state”. |
| Excessive context | Four files is acceptable for a form that hits all four concerns. |
| Handoff | Descriptions mostly point at each other. **Gap:** `useState` in hooks description steals V5-style placement (see failures). |
| Ownership | Clear after reading bodies; **trigger surface** is weaker than bodies. |

**Usefulness if all four load:** EFFECTIVE for a real form. HARMFUL if all four load for “center this div”.

## C2 — ASP.NET orders API

Skills: `api-design` + `api-security` + `aspnet-core` + `csharp-async`

| Check | Result |
| --- | --- |
| Duplication | **ProblemDetails** and **authn/z** appear in api-design, aspnet-core, and api-security. Implementer can get three error-shape lectures. |
| Contradiction | None hard. aspnet-core “[Authorize] on every sensitive endpoint” vs api-security “BOLA still required” — complementary if both load. |
| Excessive context | High if all four always-on for a one-line DTO rename. |
| Handoff | csharp-async correctly excludes middleware. aspnet-core excludes EF query shape. **Weak:** aspnet-core description still says “authn/z” broadly. |
| Ownership | Should be: design=contract, security=BOLA/tokens, aspnet=pipeline/DI, csharp=Task/cancel. |

## C3 — R3F scene

Skills: `react-three-fiber` + `threejs-performance` + `threejs-resources`

| Check | Result |
| --- | --- |
| Duplication | Dispose appears in resources and R3F (“don’t double-dispose”). Intentional handoff, not copy-paste of GPU tips. |
| Contradiction | None. R3F says Three owns the frame; performance says no alloc in loop; resources say dispose. |
| Excessive context | OK when the task mentions leak + FPS + useFrame. Too much if only “add a cube”. |
| Handoff | Explicit `React DOM ≠ GPU ≠ R3F` — **GOOD**. |
| Ownership | GOOD. V21/V22 activation supports the split. |

## Engineering cluster (Risk 1)

`debugging` / `problem-solving` / `planning` / `verification` / `code-review` / `testing-strategy` / `refactoring`

Bodies are distinct. **Descriptions are not:** `problem-solving` matches almost any product task (V1, V2, V24). That is redundant activation, not duplicate procedures.

**Decision:** retune `problem-solving` trigger; do **not** merge skills (procedures differ).

## Merge candidates?

| Pair | Merge? |
| --- | --- |
| api-design ∩ aspnet-core ProblemDetails | **No** — different stacks; **narrow descriptions** instead |
| react-components ∩ react-hooks | **No** — V6 vs V5 split is valuable if triggers are fixed |
| threejs-performance ∩ threejs-resources | **No** — V19 vs V20 split held |
| debugging ∩ problem-solving | **No** — merge would hide root-cause-first |
