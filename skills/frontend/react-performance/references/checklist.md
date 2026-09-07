# High-impact checks

| Check | Smell |
| --- | --- |
| Serial `await` of independent calls | Waterfall |
| `import { x } from 'huge-lib'` barrel | Bundle |
| Entire DB row serialized to client | RSC payload |
| Context value is new object every render | Re-render |
| `useMemo` wrapping cheap JSX | Noise |

Official Next/React docs win over this list when they disagree.
