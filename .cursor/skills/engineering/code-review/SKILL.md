---
name: code-review
description: >
  Use when reviewing an existing change: a diff, PR, patch, or
  implementation just produced. Use to produce evidence-based findings on
  architecture, correctness, security, performance, tests, and
  maintainability. Do not use to implement a feature from scratch, to run
  the full multi-iteration review loop, or to rubber-stamp “LGTM” without
  reading the change.
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
4. **Record findings** — use the schema and lifecycle in `review-loop/spec.md`; promote to `CONFIRMED` only with evidence. Map EVIDENCED RISK onto `CONFIRMED` + medium confidence **or** keep `SPECULATIVE` if the path is not shown to be hot.
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
