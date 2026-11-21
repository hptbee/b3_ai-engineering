---
name: react-three-fiber
description: >
  Use when integrating Three.js with React via React Three Fiber: Canvas,
  useFrame, declarative objects, React state vs render loop, Drei helpers,
  resource lifecycle on unmount. Do not use for DOM React performance or
  vanilla Three.js scenes without R3F.
---

# React Three Fiber

Three.js owns the frame. React owns declaration and UI state. Do not mix them carelessly.

```text
React DOM performance  ≠  Three.js GPU  ≠  R3F integration
```

## When to use

- `@react-three/fiber` components, `useFrame`, `useThree`, `<Canvas>`
- Zustand/R3F state, Drei `useGLTF`

## When not to use

- No R3F — vanilla Three → `threejs-resources` / `threejs-performance`
- CSS/React list virtualization → `react-performance`

## Procedure

1. **Keep `useFrame` cheap:** mutate refs/`object3D` properties; do not `setState` every frame.
2. **React state** for discrete UI (selected id, menu). Transient animation → refs.
3. **Dispose:** R3F disposes many owned three objects on unmount — don’t double-dispose; **do** dispose resources you created outside JSX (custom `WebGLRenderTarget`).
4. **Declarative trees:** prefer JSX meshes over imperative `scene.add` unless interop requires it.
5. **Loading:** `Suspense` + `useGLTF`; don’t block the React tree with huge parses on the main thread without a plan.
6. **Invalidation:** for mostly static scenes, render on demand (`frameloop="demand"`) when the project allows.

## Verification

Unmount the Canvas without leaking (memory) and confirm FPS when animating. INCOMPLETE if no browser.

## Failure handling

- Drei/Rapier versions — **version-sensitive**
- EnzeD 11 micro-skills — rejected; this file is the integration boundary

## Provenance

ADAPT R3F docs + three-agent-skills r3f categories (useFrame, re-renders). REJECT EnzeD pack and generic 3d-web mega-skills.
