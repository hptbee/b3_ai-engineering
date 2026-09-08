# Frontend — UI and accessibility

## Observation

Accessible UI work requires **standards-backed findings** (WCAG success criteria) and honest limits of automation. Visual polish and a11y overlap in UX dimension but a11y claims need criterion IDs and test method.

## Evidence

- `research/sources/w3c-wcag.md`
- b3 `code-review` skill lists UX/a11y as INCOMPLETE until specialist skills exist

## Pattern

```text
Review pass:
1. Scope UI change (components, forms, navigation, media)
2. Run applicable automated checks if environment allows (axe, eslint-plugin-jsx-a11y)
3. Manual checks for focus order, keyboard ops, labels, contrast (AA target)
4. Record findings with WCAG SC id + evidence (tool output or repro steps)
5. No PASS on "looks fine" without checks or explicit INCOMPLETE
```

## Why it matters

Agents frequently claim accessibility fixed without keyboard testing or semantic HTML verification. WCAG gives shared vocabulary aligned with the `review-loop/spec.md` finding schema.

## Trade-offs

- Full WCAG review is large — personal skill should default to **AA high-impact** checks (forms, nav, images, focus)
- Some criteria need human judgment — confidence stays medium/low until verified
- Design-system components may encapsulate a11y — still verify usage, not only library claims

## Potential application

Future skill `frontend-accessibility`:
- Checklist mapped to common SC (1.1.1, 1.3.1, 2.1.1, 2.4.7, 4.1.2, etc.)
- `references/wcag-quickref-links.md` — links only, not full spec
- Integrate with code-review until split triggers justify separate skill

## Confidence

High for standard; Medium for optimal checklist size for personal use
