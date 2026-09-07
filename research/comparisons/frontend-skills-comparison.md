# Frontend skills comparison

## Candidates compared

| Source | Scope | Structure | Trigger surface | Best for |
| --- | --- | --- | --- | --- |
| react.dev Thinking in React | Component/state method | Tutorial narrative | N/A (not a skill) | Design procedure |
| Next.js App Router docs | Routing, RSC, layouts | Official reference | N/A | Architecture conventions |
| TypeScript Handbook | Types, compiler | Handbook + reference | N/A | Type boundaries (embedded) |
| Vercel react-best-practices | Perf, 70 rules | Index + `rules/` files | Very broad description | Performance review catalog |
| WCAG 2.2 | Accessibility standard | Principles + SC | N/A | Finding citations |

## Structural patterns

| Pattern | Example | b3 fit |
| --- | --- | --- |
| Procedure skill | Thinking in React steps | **ADOPT** shape for component skill |
| Catalog + progressive disclosure | Vercel 70 rules | **ADAPT** for performance subset only |
| Framework convention skill | Next.js routing | **ADOPT** scoped skill |
| Standards checklist | WCAG AA hotspots | **ADAPT** a11y review skill |
| Embedded TS | Handbook slices | **ADAPT** in domain references, not standalone unless triggers demand |

## Activation risks

| Risk | Mitigation |
| --- | --- |
| Vercel-style broad description steals generic React tasks | Narrow b3 descriptions; near-miss evals vs problem-solving |
| Overlap code-review vs perf vs a11y | code-review = general pass; specialists for deep perf/a11y |
| Next.js skill fires on non-Next repos | Explicit "Next.js App Router" in description + should-not-trigger cases |

## Verdict

Do **not** import Vercel skill pack. **Do** adopt its **index + rules/** layout for a small personal performance reference set (10–15 high-impact rules max after synthesis).

Split frontend into **3–4 skills** max initially:
1. React component/state design
2. Next.js App Router (framework-scoped)
3. React/Next performance review (adapted catalog)
4. Accessibility review (WCAG-backed checklist)

TypeScript stays embedded unless evals show misfires.

## b3 alignment

Matches decision-001 (SKILL.md), decision-003 (progressive disclosure), reject-monolithic-engineering-skill.

## Confidence

Medium-High
