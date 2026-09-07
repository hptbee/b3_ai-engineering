# Frontend — React component design

## Observation

Official React teaching centers on a **repeatable decomposition method**, not API memorization: mockup → component hierarchy → static render → minimal state → inverse data flow.

## Evidence

- `research/sources/react-dev-thinking-in-react.md`
- Contrasts with Vercel skill (`vercel-react-best-practices.md`) which centers performance catalogs

## Pattern

```text
1. Map data model shape → component tree
2. Build static UI (props only, no state)
3. Identify minimal interactive state
4. Place state at lowest common ancestor
5. Wire controlled updates (props down, events up)
```

## Why it matters

Agents often jump to hooks and context before structure, producing over-nested state and unnecessary effects. The static-first phase is a natural **verification checkpoint** (render matches mockup before behavior).

## Trade-offs

- Method does not cover Server Components — must pair with Next.js source
- Does not address performance (waterfalls, memo) — separate skill scope
- "One component one concern" is subjective at margins (table header example in docs)

## Potential application

Future skill `frontend-react-components` (name TBD):
- Small SKILL.md with procedure above
- `references/` for hooks, lists/keys, immutability snippets
- Trigger: "break this UI into components", "where should state live", "implement this mockup"
- Near-miss: performance-only tasks → performance skill; generic bug fix → problem-solving

## Confidence

High (official primary source)
