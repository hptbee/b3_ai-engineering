---
name: threejs-performance
description: >
  Use when Three.js rendering is slow: draw calls, instancing, LOD,
  culling, texture size, lights/shadows, CPU vs GPU bottlenecks, work in
  the animation loop, heavy asset parse. Do not use for React re-renders,
  dispose-only leaks, or instancing a handful of meshes with no FPS issue.
---

# Three.js GPU performance

Fewer draws. Less per-frame allocation. Smaller textures.

## When to use

- Low FPS, GPU bound, too many meshes
- Shadows killing mobile

## When not to use

- Dispose/teardown → `threejs-resources`
- R3F re-render of React tree → `react-three-fiber` (and `react-performance` for DOM)

## Procedure

1. **Measure** `renderer.info.render.calls`, FPS, and whether the bottleneck is GPU (fills/draws) or CPU (JS in the loop / parse).
2. **Draw calls:** instancing (`InstancedMesh`) or merge static geometry; target far fewer than “one mesh per object” for crowds.
3. **Loop:** no `new` / array alloc / `getWorldPosition` spam in the animation loop; cache.
4. **Assets:** don’t parse huge GLTF on the main thread without a plan; texture size vs need.
5. **Textures:** power-of-two, compressed (KTX2) when pipeline exists; don’t ship 4k everywhere.
6. **Lights/shadows:** few real-time lights; tight shadow cameras; bake if static.
7. **LOD / frustum culling** for large scenes — not for three crates.
8. **Pixel ratio** cap (especially mobile).

## Verification

Before/after draw calls or FPS, or INCOMPLETE.

## Failure handling

- WebGPU/TSL — **version-sensitive**; skip if project is WebGL-only
- Physics engines — out of this skill unless they dominate the frame

## Provenance

ADAPT three-agent-skills performance categories (render, drawcall, material). Not copied rule files. Official Three.js performance tips apply when they conflict.
