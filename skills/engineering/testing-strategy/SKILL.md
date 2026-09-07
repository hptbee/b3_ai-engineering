---
name: testing-strategy
description: >
  Use when choosing what to test, writing tests for new behavior or a bug,
  or judging whether existing tests could catch the risk. Do not use as a
  mandate to rewrite working code as TDD, for running tests as evidence
  of a claim (verification), or for UI-only visual QA without a test plan.
---

# Testing strategy

Tests should catch the risk. Coverage theater and mock-only tests do not.

## When to use

- New behavior or bugfix that should not regress
- Asking “what tests belong here?”
- Reviewing whether tests could fail if the bug returned

## When not to use

- Declaring “tests passed” → `verification` (must run them)
- Debugging without a test question → `debugging`
- Full product implementation loop → `problem-solving`

Near miss: “add unit tests” without running them is this skill then verification.

## Procedure

1. **Name the risk** (behavior that must not silently break).
2. **Choose the cheapest honest test:**
   - Unit: pure logic, parsing, mapping
   - Integration: DB, HTTP, auth, EF queries
   - UI/e2e: user-visible contracts only
3. **Prefer a failing test first** for new behavior and reproduced bugs **when the harness exists**. If the code already exists (brownfield), add a test that would have failed, then fix — do not delete working code to satisfy ritual.
4. **Assert real behavior**, not mock call counts, unless the mock *is* the contract (e.g. outbound HTTP).
5. **Do not test implementation trivia** (private method names, CSS class strings) unless that *is* the contract.
6. **Run the tests** via `verification`. Unrun tests are not evidence.

## Progressive disclosure

- `references/test-quality.md` — good vs weak tests
- Rejected default: `research/rejected/reject-tdd-iron-law-default.md`

## Verification

Skill applied well when a named risk has a test that would fail if the bug returned, **or** INCOMPLETE with why tests could not be added/run.

## Failure handling

- No test runner → INCOMPLETE; do not invent a green suite
- Untestable blob → say so; smallest seam to make it testable, or mark gap
- Flakes → do not treat as PASS

## Provenance

ADAPT Superpowers TDD (red/green intent, honest tests). REJECT iron law. Tiki TDD skill: observe only.
