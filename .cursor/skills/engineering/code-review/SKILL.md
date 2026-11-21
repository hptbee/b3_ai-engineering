---
name: code-review
description: >
  Use when reviewing an existing change: a diff, PR, patch, or
  implementation just produced. Use to produce evidence-based findings on
  architecture, correctness, security, performance, simplification/residue,
  tests, and maintainability. Do not use to implement a feature from
  scratch, to run the full multi-iteration review loop, or to rubber-stamp
  “LGTM” without reading the change.
---

# Code review

Produce an honest review of a defined change. This skill is **one review pass**. The iterative loop is `review-loop/spec.md`, run by `review-loop/strategy.md`.

## When to use

- User asks to review a PR, diff, or recent edits
- After implementation, before claiming the work is ready
- When producing findings with separate severity and confidence, and a lifecycle status

## When not to use

- Implementing the feature itself → `problem-solving`
- Researching external review playbooks → `research-engineering-patterns`
- Declaring the full loop done (iteration limits, re-review after fixes) without that process
- Accessibility-only, security-only, performance-only, or UX-only deep dives: use the specialist agent/skill when it exists (`performance-reviewer` is hot-path only). Otherwise cover lightly here or mark the dimension INCOMPLETE

Near miss: “write tests for this PR” → implementation, then verification. “Is this safe to ship?” → this skill plus verification evidence, not a vibe.

## Procedure

1. **Scope** — what is in/out; empty or wrong target → INCOMPLETE.
2. **Understand** — read the change; restate intent; do not invent requirements.
3. **Review** — examine the scoped dimensions in `review-loop/spec.md`; skip only with a recorded reason.
   **Performance dimension (every pass, light):** do not skip silently. Classify findings:
   - **CONFIRMED** — measured stall/regression or a reproduction (N+1 SQL log, blocked event loop, profiler).
   - **EVIDENCED RISK** — known hot-path pattern in the diff (unbounded list query, `useFrame`+`setState`, sync CPU on request) without a profile yet. May block if the path is clearly hot; otherwise record confidence honestly.
   - **SPECULATIVE** — “could be faster”, memo-everywhere, extra cache with no load. **Must not** block the PR.
   Load the smallest domain performance skill when the diff matches that stack. Independent depth: `.cursor/agents/performance-reviewer.md` only when `review-loop/strategy.md` routes it — not on every PR.

   **Simplification / implementation residue dimension (every pass):**
   Do not only ask: “Is this code correct?” Also ask:
   *“Given the final implementation and current requirements, is all of this code still necessary?”*
   Look for **change residue**: code that remains reachable/understandable but exists primarily because of an earlier implementation, maintenance, or fix state rather than a current requirement.
   Inspect nearby code, call sites, tests, and current contracts (use git history only when useful; do not perform archaeology on trivial reviews).
   Target categories (risk-based, not a giant checklist):
   - duplicated business logic, duplicate conditions, equivalent or redundant branches
   - unreachable or effectively unreachable paths, obsolete fallback behavior, stale compatibility paths
   - dead feature flags, temporary migration logic left behind, accidental permanent workarounds
   - redundant state, redundant derived state, unnecessary React effects, duplicate event subscriptions
   - duplicate mappings/transforms, duplicate validation, duplicate error handling
   - pass-through wrappers with no remaining responsibility, abstractions whose original consumer disappeared
   - obsolete overloads, stale DTO/model fields, duplicated API contracts, obsolete caching layers
   - defensive code for impossible states when impossibility is proven by current contracts
   - comments describing removed behavior, completed TODOs, obsolete tests or fixtures protecting removed behavior
   - old code paths retained after a replacement became canonical

   **Classification of simplification findings:**
   - **CONFIRMED REDUNDANCY** — repository evidence shows the logic has no remaining responsibility or is fully duplicated elsewhere. Only confirmed items become cleanup requirements.
   - **LIKELY REDUNDANT** — strong evidence, but one dependency or requirement remains uncertain. Keep SPECULATIVE / INVESTIGATING; do not delete without proof.
   - **INTENTIONAL COMPLEXITY** — named current responsibility holds (compatibility, correctness, performance, security, external consumer, trust boundary). Accept, do not delete.
   - **UNKNOWN** — evidence cannot determine safety. Do not convert uncertainty into a deletion request.
   This is not aesthetic cleanup or “make code shorter”. Never refactor unrelated code.
4. **Record findings** — use the schema and lifecycle in `review-loop/spec.md`; promote to `CONFIRMED` only with evidence. Map EVIDENCED RISK onto `CONFIRMED` + medium confidence **or** keep `SPECULATIVE` if the path is not shown to be hot. Map CONFIRMED REDUNDANCY onto category `simplification` + `CONFIRMED`.
5. **Consolidate** — merge duplicates; separate blockers from nits; speculative ≠ confirmed.
6. **Tie to verification** — name probes/tests; do not claim they passed unless run (`verification` skill).

## Progressive disclosure

- Finding schema, lifecycle, dimensions, false convergence: `review-loop/spec.md`
- Specialist roles when isolation matters: `.cursor/agents/reviewer.md`, `.cursor/agents/security-reviewer.md`, `.cursor/agents/architecture-reviewer.md`, `.cursor/agents/performance-reviewer.md`, `.cursor/agents/fixer.md`
- Evidence and verification rules: `rules/evidence-and-provenance.md`, `rules/verification.md`

## Verification

A review is complete only if the scoped dimensions were actually examined or explicitly marked incomplete. Tool failure during review → `UNKNOWN / INCOMPLETE` for that dimension, not PASS.

## Failure handling

- Diff too large → sample by risk, state what was not reviewed
- Cannot run tests → do not infer they pass; mark verification incomplete
- Disagreement with a prior review → record both views; do not average them into a fake PASS
- No findings → possible; still record what was checked, or the empty review is not evidence of quality
