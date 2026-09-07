# React — Thinking in React (official docs)

## Source

https://react.dev/learn/thinking-in-react

## Tier

Tier 1

## Purpose

Official React mental model for component design, state placement, and data flow.

## Architecture

- UI decomposed into **components** matching data model shape
- Five-step workflow: mockup → hierarchy → static version → state placement → inverse data flow
- Static-first: build non-interactive version before adding state
- State lives at lowest common ancestor of components that need it

## Important Patterns

- Component hierarchy mirrors JSON/data model structure
- Props down, events up (inverse data flow)
- Separate concerns: one component, one job; decompose when it grows
- Do not use state for static rendering phase
- Controlled vs uncontrolled inputs for form state ownership

## Skill Design

Official docs do not prescribe agent skills. Patterns map to **procedure skills** for component breakdown and state placement — not a monolithic "React skill" covering all APIs.

## Rules / Instructions

Docs emphasize **method** (how to think) over lint rules. Constraints (keys in lists, immutability) appear in linked pages, not as agent frontmatter.

## Agents

N/A — product documentation.

## Commands / Workflows

Tutorial workflow is linear: hierarchy → static → minimal state → full interactivity.

## Evaluation

No eval harness. Tutorial success = working searchable product table.

## Portability

Framework-agnostic thinking applies beyond React; JSX-specific patterns require React context.

## Strengths

- Clear separation of static vs interactive phases
- Explicit state ownership rule (lowest common ancestor)
- Teaches data flow before hooks complexity

## Weaknesses / Trade-offs

- Does not cover Server Components, Next.js, or performance
- Class-era patterns removed; older sources may conflict
- Accessibility not central in this page

## Interesting Implementation Details

- `FilterableProductTable` tutorial encodes full pipeline
- Controlled input pattern: parent owns filter string state
- Category rows vs product rows as composition example

## Relevant Files

- react.dev/learn/thinking-in-react
- Linked: your-first-component, passing-props, state-a-components-memory

## Evidence

- Fetched 2026-09-07: five-step UI breakdown, static-first, state at LCA, inverse data flow

## Relevance to b3-ai-engineering

Foundation for a **focused** frontend skill on component/state design — not a 70-rule performance catalog. Pair with Next.js and TypeScript sources before synthesis.

## Initial Recommendation

ADOPT (mental model for future `frontend-react` skill body); ADAPT (condense to agent procedure, add verification step)
