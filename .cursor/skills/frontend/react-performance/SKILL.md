---
name: react-performance
description: >
  Use when React/Next UI is slow: waterfalls, bundle size, unnecessary
  re-renders, large lists, expensive render work, client/server data
  fetching. Do not use for first-pass component design, Three.js GPU
  cost, accessibility, or “add memo everywhere” with no measured cost.
---

# React performance

Fix real cost. Measure before memo. Do not sprinkle memo by default.

## When to use

- Slow page load, serial awaits, huge JS
- Re-render storms, large lists janking, expensive work in render
- RSC payload too large

## When not to use

- Structure/state ownership → `react-components`
- Hook identity / “should I useCallback?” with no list/bundle issue → `react-hooks`
- GPU/draw calls → `threejs-performance`
- R3F `useFrame` allocations → `react-three-fiber`
- Copy/label PRs or “make it faster” with no symptom and no profile → do not optimize

## Procedure

Review in this order (adapted from Vercel impact ranking, rewritten):

1. **Waterfalls:** independent async work in `Promise.all`; don’t await unused work; start fetches early.
2. **Bundle:** avoid barrel imports of huge packages; dynamic-import heavy UI.
3. **Server:** don’t pass fat objects to client components; no request-scoped mutable module state; cache per-request dedupe where the framework provides it.
4. **Client fetch:** don’t stampede; abort/dedupe.
5. **Re-renders:** subscribe to the slice you need; derive booleans; no components created in render.
6. **Lists:** window/virtualize when a **measured** large list janks; don’t virtualize ten rows.
7. **Expensive compute:** move out of render or memo **after** the profiler shows it; not first.
8. **Memo** last, and only around proven expensive subtrees.

Open `references/checklist.md` for profiler/smells. No measurement → claim INCOMPLETE, not “optimized”.

## Verification

Measure before/after if tools exist (React Profiler, bundle analyzer, Network). Otherwise INCOMPLETE.

## Failure handling

- Next.js-only APIs (`after()`, `cache()`) — **version-sensitive**; skip if not Next
- No profiler → qualitative only, labeled incomplete

## Provenance

ADAPT vercel-labs/agent-skills react-best-practices **structure and priorities**, not 70 rule files. MIT; rewritten.
