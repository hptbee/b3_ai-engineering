---
name: react-performance
description: >
  Use when React/Next UI is slow: waterfalls, bundle size, unnecessary
  re-renders, client/server data fetching. Do not use for first-pass
  component design, Three.js GPU cost, or accessibility.
---

# React performance

Fix real cost. Do not sprinkle memo by default.

## When to use

- Slow page load, serial awaits, huge JS
- Re-render storms
- RSC payload too large

## When not to use

- Structure/state ownership → `react-components`
- GPU/draw calls → `threejs-performance`
- R3F `useFrame` allocations → `react-three-fiber`

## Procedure

Review in this order (adapted from Vercel impact ranking, rewritten):

1. **Waterfalls:** independent async work in `Promise.all`; don’t await unused work; start fetches early.
2. **Bundle:** avoid barrel imports of huge packages; dynamic-import heavy UI.
3. **Server:** don’t pass fat objects to client components; no request-scoped mutable module state; cache per-request dedupe where the framework provides it.
4. **Client fetch:** don’t stampede; abort/dedupe.
5. **Re-renders:** subscribe to the slice you need; derive booleans; no components created in render.
6. **Memo** last, and only around proven expensive subtrees.

Open `references/checklist.md` only if the above is not enough.

## Verification

Measure before/after if tools exist (profiler, bundle analyzer, Network). Otherwise INCOMPLETE — do not claim “optimized”.

## Failure handling

- Next.js-only APIs (`after()`, `cache()`) — **version-sensitive**; skip if not Next
- No profiler → qualitative only, labeled incomplete

## Provenance

ADAPT vercel-labs/agent-skills react-best-practices **structure and priorities**, not 70 rule files. MIT; rewritten.
