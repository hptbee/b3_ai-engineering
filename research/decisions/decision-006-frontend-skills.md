# Decision 006 — Frontend skills approach

## Context

Track A researched React, TypeScript, Next.js, UI/a11y, and OSS skill examples for future domain skills. Portable core must not fork Vercel content or create fake completeness.

## Options Considered

1. Import `vercel-labs/agent-skills` react-best-practices wholesale
2. Single monolithic `frontend` skill covering React + Next + TS + a11y + perf
3. **Split focused skills** with adapted structure from Vercel catalog
4. Defer all frontend skills until product work demands them

## Evidence

- Sources: `react-dev-thinking-in-react.md`, `nextjs-app-router.md`, `typescript-handbook.md`, `vercel-react-best-practices.md`, `w3c-wcag.md`
- Findings: `frontend-react.md`, `frontend-nextjs.md`, `frontend-ui-accessibility.md`
- Comparison: `frontend-skills-comparison.md`
- Rejected pattern: `reject-monolithic-engineering-skill.md`

## Decision

**ADAPT** phased frontend skill set (synthesis phase — not implemented in this track):

| Skill (planned) | Source basis | Decision |
| --- | --- | --- |
| React component/state design | react.dev Thinking in React | **ADOPT** procedure |
| Next.js App Router | Next.js official routing/RSC docs | **ADOPT** scoped conventions |
| React/Next performance review | Vercel rule **structure** only | **ADAPT** ~10–15 high-impact rules, rewritten |
| Accessibility review | WCAG 2.2 AA hotspots | **ADAPT** checklist + SC citations |
| TypeScript standalone | TS Handbook | **DEFER** — embed in domain skills first |

**REJECT:**
- Wholesale copy of Vercel 70 rules or AGENTS.md compiled dump
- Monolithic frontend mega-skill
- Importing skill aggregators

## Rationale

Official docs give authoritative **methods**; Vercel skill gives scalable **catalog layout** for performance; WCAG gives **evidence vocabulary** for a11y. Splitting improves trigger evals and matches progressive disclosure.

## Consequences

- Synthesis phase creates skills under `skills/frontend/` (or similar) with trigger fixtures before catalog growth
- `code-review` keeps light UX/a11y until `frontend-accessibility` exists
- Research provenance recorded; no skill files in Track A

## Confidence

Medium-High
