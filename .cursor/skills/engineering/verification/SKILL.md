---
name: verification
description: >
  Use when claiming that work works, when finishing implementation, when
  asked to confirm tests, builds, behavior, or reviews, or when evidence
  is missing. Use after fixes and before declaring a review loop done.
  Do not use for design-only discussion, for writing tests without running
  them, or for explaining verification philosophy without a concrete claim.
---

# Verification

Verification is evidence. Assertion is not.

## When to use

- Any claim that code, tests, builds, UX, or a review “passed”
- After implementation or a fix
- When a tool failed and someone wants to treat that as success
- When deciding PASS vs FAIL vs UNKNOWN / INCOMPLETE

## When not to use

- Pure design or planning with no claim of correctness-in-the-world
- Authoring a test that will be run later (writing ≠ running)
- Taxonomy questions (“what is a rule vs a skill?”)

Near miss: “add unit tests for this module” → testing/implementation work, then this skill when those tests are used as evidence. “Did CI pass?” → this skill.

## Procedure

1. **Name the claim** in one sentence (what is supposed to be true).
2. **Name the evidence** that would confirm it (command, probe, screenshot of behavior, log, official check).
3. **Run or obtain that evidence.** Record the command or action and the observed result.
4. **Map result to outcome:**
   - evidence produced and supports the claim → `PASS`
   - evidence produced and contradicts the claim → `FAIL`
   - evidence missing, tool failed, skipped, timed out, or environment cannot run it → `UNKNOWN / INCOMPLETE`
5. **After a fix**, re-run the evidence that would have caught the issue. State what was re-run.
6. **Do not upgrade** incomplete checks to PASS because the code “looks right”. A “it’s faster” claim without before/after measurement is INCOMPLETE, not PASS.

## Progressive disclosure

- Hard constraints: `rules/verification.md`
- Review-loop use of outcomes: `review-loop/spec.md`

## Verification of this skill

This skill is applied correctly when the write-up lists what ran, what did not, and the outcome label. A summary with no commands, no results, and a success claim is a failed use of the skill.

## Failure handling

- No test runner / no browser / no network → `UNKNOWN / INCOMPLETE` plus the blocker
- Flaky or inconclusive run → do not call PASS; rerun or mark incomplete
- Wrong environment (cannot exercise the change) → incomplete, not a skip disguised as success
- User asks to “just say it works” → refuse; report the actual outcome
