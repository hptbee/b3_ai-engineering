# Frontend — Next.js App Router

## Observation

App Router encodes architecture in **filesystem conventions** and **server-first rendering**. Routing, layouts, and data-loading boundaries are distinct concerns from React component design.

## Evidence

- `research/sources/nextjs-app-router.md`
- Vercel skill server-* rules (`vercel-react-best-practices.md`)

## Pattern

| Concern | Convention |
| --- | --- |
| Route segment | Folder under `app/` |
| Page UI | `page.tsx` default export |
| Shared chrome | `layout.tsx` with `children` |
| Dynamic URL | `[param]` folders; async `params` |
| Server fetch | Async Server Component page |
| Client interactivity | `'use client'` boundary + hooks |
| Navigation | `Link` / `useRouter` |
| Dynamic rendering | `searchParams` on server page |

## Why it matters

Common agent failures: client hooks in Server Components, fetching in wrong layer, serial awaits (waterfalls), module-level mutable state in RSC.

## Trade-offs

- Next.js-specific — description must say "Next.js App Router" for trigger evals
- Overlap with Vercel performance skill on server rules — b3 should split **architecture** vs **performance review**

## Potential application

Future skill `frontend-nextjs-app-router`:
- Procedure: identify route segment → choose server vs client → colocate data fetch → verify build
- References: caching, server actions (separate research pass)
- Near-miss: plain React SPA without Next → react component skill only

## Confidence

High for routing page; Medium for full App Router surface (single source slice)
