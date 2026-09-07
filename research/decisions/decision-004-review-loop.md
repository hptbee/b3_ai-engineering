# Decision 004 — Review loop design

## Context

b3 review-loop spec needs validation against implemented systems before runtime work.

## Options Considered

1. **b3 spec** (lifecycle, severity≠confidence, false convergence, caps)
2. SWE-Review-style independent reconstruction (always)
3. dev-loop-style dual-model validated loop
4. Open Code Review 8-phase + discourse (default)
5. Single-pass code-review skill only (no loop)

## Evidence

- Comparisons: `review-loop-comparison.md`
- Findings: `review-loop-patterns.md`, `failure-handling.md`
- Sources: SWE-Review, dev-loop, calimero, OCR, Anthropic evaluator-optimizer

## Decision

**ADAPT** b3 existing review-loop spec with these research-backed additions for runtime v1:

- Mandatory **finding validation** before fix (from dev-loop)
- **Independent review pass** separate from implementer (from SWE-Review/Cursor subagent guidance)
- Optional **reconstruction** only for high-risk changes (DEFER as default-on)
- **Iteration cap** with INCOMPLETE outcome (already in b3; align default max with 3–5 range seen in field)
- **Stagnation detection** beyond cap (b3 spec; borrow calimero delta ideas for PR context later)

**REJECT** OCR 8-phase pipeline as default personal system workflow (too heavy).

## Rationale

b3 spec already strong; field adds validation + independence emphasis; avoid over-engineering phases.

## Consequences

- `code-review` skill remains one pass; loop stays separate layer
- Runtime implementation deferred; research does not modify `review-loop/` code yet
- Future agent roles: reviewer/security/performance as independent mandates

## Confidence

Medium-High (runtime details like default max iteration still tunable)
