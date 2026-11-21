---
name: react-components
description: >
  Use when designing or implementing React UI: component hierarchy, state
  ownership, props vs state, composition, forms, avoiding giant components
  and duplicated state. Do not use for Next.js routing-only tasks, React
  performance catalogs, accessibility-only review, or Three.js/R3F scenes.
---

# React components

Structure UI from data. Place state at the lowest common ancestor. Compose instead of boolean-prop explosion.

## When to use

- Mockup → components
- “Where should this state live?”
- Forms, lists, lifting state, compound components

## When not to use

- `useEffect` / hook dependency bugs → `react-hooks`
- Waterfalls, memo, bundle → `react-performance`
- Keyboard/a11y criteria → `accessibility`
- Canvas/WebGL → `threejs-*` / `react-three-fiber`

## Procedure

1. **Break the UI** to match the data model (official Thinking in React).
2. **Static first:** props only; no state, no effects.
3. **Minimal state:** list what changes over time; derive the rest during render.
4. **Ownership:** state lives in the nearest parent that can pass it down. Inverse data flow (callbacks up).
5. **Composition:** prefer children/slots over `isCompact && isHero && showBadge` APIs. See `references/composition.md`.
6. **Guardrails:** no duplicated state, no giant files without a split reason, no context for values used by one child.

## Progressive disclosure

- `references/composition.md`
- Official: https://react.dev/learn/thinking-in-react

## Verification

Render the static tree against the mockup; then interact. Evidence: screenshot of behavior, component test, or INCOMPLETE.

## Failure handling

- Class-component legacy → follow project patterns; do not rewrite to hooks without mandate
- RSC vs client unclear → read the product repo; Next.js conventions are project requirements

## Provenance

ADOPT react.dev Thinking in React. ADAPT Vercel composition-patterns (boolean props, compound components) — not the full rule pack.
