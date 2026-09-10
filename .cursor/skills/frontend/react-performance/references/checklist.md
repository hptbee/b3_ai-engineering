# High-impact checks

| Check | Smell |
| --- | --- |
| Serial `await` of independent calls | Waterfall |
| `import { x } from 'huge-lib'` barrel | Bundle |
| Entire DB row serialized to client | RSC payload |
| Context value is new object every render | Re-render |
| `useMemo` wrapping cheap JSX | Noise |
| Mapping 10k rows with no windowing after a jank profile | Lists |
| Heavy filter/sort in render with Profiler showing commit time | Compute |

**Profiler:** React Profiler / DevTools Performance. No capture → INCOMPLETE, not CONFIRMED.

Official Next/React docs win over this list when they disagree.
