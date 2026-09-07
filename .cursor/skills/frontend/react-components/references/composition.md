# Composition (short)

## Prefer

- Compound parts: `<Select><Select.Trigger/><Select.List/></Select>`
- Explicit variants: `PrimaryButton` vs `isPrimary` plus five other flags
- `children` for slots instead of `renderHeader={() => ...}` unless the caller must intercept render

## Avoid

- Boolean prop matrices that encode mutually exclusive modes
- Context that exists only to avoid passing three props one level

React 19: `forwardRef` often unnecessary; `use()` vs `useContext` is **version-sensitive** — follow the project React version.

Authority: Vercel composition-patterns (adapted). Project React version wins.
