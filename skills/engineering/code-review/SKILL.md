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

Produce an honest review of a defined change. This skill is one review pass. The iterative loop (fix → verify → re-review, limits, stagnation) is specified in `docs/review-loop.md` and is not fully implemented yet.

## When to use

- User asks to review a PR, diff, or recent edits
- After implementation, before claiming the work is ready
- When producing findings with separate severity and confidence, and a lifecycle status

## When not to use

- Implementing the feature itself → `problem-solving`
- Researching external review playbooks → `research-engineering-patterns`
- Declaring the full loop done (iteration limits, re-review after fixes) without that process
- Accessibility-only, security-only, or UX-only deep dives once those specialist skills exist — until then, cover them lightly here or mark the dimension INCOMPLETE

Near miss: “write tests for this PR” → implementation, then verification. “Is this safe to ship?” → this skill plus verification evidence, not a vibe.

## Procedure

1. **Scope**  
   What is in the change, what is out, which dimensions apply. If there is no meaningful target (empty diff, wrong branch), stop: INCOMPLETE.

2. **Understand**  
   Read the change and surrounding code. Restate intent. If intent is unclear, say so; do not invent requirements.

3. **Review dimensions** (skip only with a recorded reason):
   - Architecture (boundaries, coupling, data flow)
   - Correctness (logic, edge cases, contracts)
   - Security (trust boundaries, authz, injection, secrets)
   - Performance (obvious hot paths, N+1, unbounded work)
   - Tests (meaningful coverage of the risk, not only presence of files)
   - Maintainability (naming, complexity, dead code, API clarity)

4. **Record findings** using the schema in `docs/review-loop.md` (id, severity, confidence, status, category, location, description, evidence, suggested_fix, verification).
   - **Severity** = harm if real (`critical` / `high` / `medium` / `low`). **Confidence** = certainty it exists (`high` / `medium` / `low`). `critical` + `low` confidence is not a confirmed critical defect.
   - Status starts `NEW` / `INVESTIGATING`. Promote to `CONFIRMED` only with evidence. Park thin items as `SPECULATIVE`; do not flood the review.
   - Categories include correctness, security, performance, architecture, maintainability, testing, reliability, ux.

5. **Consolidate**  
   Merge duplicates. Drop stale items. Separate blockers from nits. Do not present nits as blockers. Speculative ≠ confirmed.

6. **Tie to verification**  
   If a finding requires a test or probe, say which. Do not claim tests passed unless they were run (`verification` skill).

## Progressive disclosure

- Loop, finding lifecycle, false convergence, iteration limits: `docs/review-loop.md`
- Evidence rule: `rules/evidence-and-provenance.md`
- Verification rule: `rules/verification.md`

Specialist reviewer agents are specified in `agents/README.md` and are not implemented yet.

## Verification

A review is complete only if the scoped dimensions were actually examined or explicitly marked incomplete. Tool failure during review → `UNKNOWN / INCOMPLETE` for that dimension, not PASS.

## Failure handling

- Diff too large → sample by risk, state what was not reviewed
- Cannot run tests → do not infer they pass; mark verification incomplete
- Disagreement with a prior review → record both views; do not average them into a fake PASS
- No findings → possible; still record what was checked, or the empty review is not evidence of quality
