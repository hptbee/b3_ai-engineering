---
name: react-hooks
description: >
  Use when writing or fixing React hooks: useEffect, effect dependencies,
  derived state vs copied props, stale closures, and async in UI. Do not
  use for where state lives in the component tree (react-components),
  performance catalogs, or R3F useFrame.
---

# React hooks

Effects are for synchronizing with the outside world. Derived data belongs in render.

## When to use

- Effect runs too often / not enough
- Stale closures, missing deps
- Fetching in effects vs better data APIs
- “Should I memo this callback/value?” (only if the issue is hook identity, not bundle/waterfalls)

## When not to use

- Hierarchy and state placement → `react-components`
- Bundle/waterfall → `react-performance`
- `useFrame` / Three.js subscriptions → `react-three-fiber`

## Procedure

1. **Derive, don’t store:** if value can be computed from existing state/props, do not `useEffect` + `setState`.
2. **Effects:** identify the external system (DOM, subscription, fetch). Cleanup must unsubscribe/abort.
3. **Dependencies:** list what the effect reads. Do not lie to the linter; do not copy objects/functions inline if that retriggers forever — extract or stabilize for a real reason.
4. **Async:** abort on unmount; handle race (ignore stale responses). Do not ignore promise rejection.
5. **Memo:** only when measured or when referential identity is a real child contract. Premature `useMemo`/`useCallback` everywhere is noise.
6. **No components defined inside components.**

## Verification

Reproduce the bug (double-fetch, stale UI) then show it gone, or INCOMPLETE.

## Failure handling

- React 19 `use()` / compiler — **version-sensitive**; follow project docs
- Server Components cannot use client hooks — move the boundary

## Provenance

react.dev (You Might Not Need an Effect). Vercel rerender rules sampled, not imported.
