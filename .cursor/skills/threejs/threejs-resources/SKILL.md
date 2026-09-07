---
name: threejs-resources
description: >
  Use when creating or tearing down Three.js objects: geometries,
  materials, textures, render targets, loaders, GLTF, animation mixers,
  renderer dispose. Do not use for React DOM performance or R3F hook
  integration details.
---

# Three.js resources

Undisposed GPU objects leak. Allocate in setup, not per frame.

## When to use

- Scene setup, model load, hot-reload, route unmount
- Memory climbing after navigating away from a canvas

## When not to use

- Draw-call / instancing / LOD strategy → `threejs-performance`
- `useFrame`, `<primitive>`, R3F lifecycle → `react-three-fiber`

## Procedure

1. **Own a dispose path** for every created `BufferGeometry`, `Material`, `Texture`, `WebGLRenderTarget`.
2. **Materials:** dispose arrays of materials; dispose maps on the material.
3. **GLTF:** traverse and dispose, or use a documented helper; don’t drop the reference and hope GC frees GPU memory.
4. **Renderer:** `dispose()` when the canvas goes away; handle context lost if the product needs it.
5. **Reuse** geometries/materials across meshes when they are identical.
6. **Loaders:** prefer glTF; don’t leave unused assets in memory.

Vanilla dispose sketch (adapt, don’t paste blindly):

```text
geometry.dispose()
material.dispose() / material.map?.dispose()
renderer.dispose()
```

## Verification

Navigate away and watch `renderer.info.memory` or OS GPU memory if available. Else INCOMPLETE.

## Failure handling

- **version-sensitive** Three.js APIs (WebGPURenderer, TSL) — follow project three version
- Official: https://threejs.org/docs/#manual/en/introduction/How-to-dispose-of-objects

## Provenance

ADAPT emalorenzo/three-agent-skills **memory category** + Three.js dispose manual. REJECT 120-rule import.
