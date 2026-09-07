# Next.js App Router (official docs)

## Source

https://nextjs.org/docs/app/building-your-application/routing

## Tier

Tier 1

## Purpose

Official Next.js App Router conventions: file-system routing, layouts, server/client boundaries.

## Architecture

- **`app/` directory**: folders = route segments; `page.tsx` = UI; `layout.tsx` = shared shell
- **Nested layouts** preserve state across navigation; root layout requires `html`/`body`
- **Dynamic segments** `[slug]` with async `params` (Promise in current docs)
- **Server Components default**: async pages fetch on server; `searchParams` opts into dynamic rendering

## Important Patterns

- File-system routing replaces `pages/` config for new apps
- `Link` for client navigation with prefetch
- `generateStaticParams` for static generation of dynamic routes
- `PageProps` / `LayoutProps` type helpers from `next dev` / `next build` / `next typegen`
- Server `searchParams` vs client `useSearchParams` — choose by where data loads

## Skill Design

Next.js docs are extensive; agent skills should **scope by task** (routing, data fetching, RSC boundaries) rather than one mega-skill. Vercel's react-best-practices skill merges React + Next.js performance — useful reference, different scope.

## Rules / Instructions

Framework conventions act as **project rules** when using App Router (e.g. colocate route files). Not portable outside Next.js repos.

## Agents

N/A

## Commands / Workflows

Dev/build/typegen generate route types; no agent command layer.

## Evaluation

No official agent evals. Correctness = builds, routes resolve, RSC boundaries respected.

## Portability

Next.js-specific. Portable core should not embed App Router paths in generic skills — adapter or domain skill with explicit scope.

## Strengths

- Co-located routing + UI reduces config drift
- Layout nesting matches UI composition
- Clear server/client split guidance in broader docs

## Weaknesses / Trade-offs

- Async `params`/`searchParams` API churn requires doc freshness
- Easy to misuse client hooks in Server Components
- Performance rules live elsewhere (Vercel skill, Next.js caching docs)

## Interesting Implementation Details

- Parallel routes (`@slot`) typed via `LayoutProps`
- Dynamic rendering triggered by `searchParams` on server pages

## Relevant Files

- nextjs.org/docs/app/**
- Related: data fetching, caching, server actions (not fully covered in routing page)

## Evidence

- Fetched 2026-09-07: app router file conventions, nested layouts, dynamic segments, searchParams behavior

## Relevance to b3-ai-engineering

Separate **Next.js routing/RSC** skill scope from generic React component skill. Mark host/framework scope in description for trigger evals.

## Initial Recommendation

ADOPT (routing/RSC conventions for future skill); DEFER full Next.js surface to progressive references
