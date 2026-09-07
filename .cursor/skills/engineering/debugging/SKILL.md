---
name: debugging
description: >
  Use when a bug, test failure, unexpected behavior, or regression needs
  root-cause investigation before a fix. Use when the agent is about to
  guess a patch. Do not use for greenfield features, isolated code review
  of a known-good diff, or claiming tests passed.
---

# Debugging

Find the cause before changing code. Symptom patches without a cause are not a solution.

Adapted from Superpowers systematic debugging (phases, evidence, one hypothesis) without TDD iron-law or host-specific sub-skills.

## When to use

- Failures, flakes, “it broke after deploy”
- Tests fail and the cause is unclear
- Performance that looks like a bug (hangs, leaks) until proven otherwise

## When not to use

- Implementing a new feature with a clear spec → `problem-solving` / `planning`
- Reviewing an existing PR → `code-review`
- “Does this work?” after a known fix → `verification`

Near miss: “fix this bug” with a reproduction already in hand still **starts here** (confirm cause), then implement.

## Procedure

1. **Reproduce** with exact steps. If not reproducible, gather data — do not patch folklore.
2. **Read the failure** (message, stack, logs) completely.
3. **Check recent change** (diff, config, deps, environment).
4. **Locate the broken boundary** (client/server, middleware/handler, query/app). Add a probe only if needed.
5. **One hypothesis:** “X is the cause because Y.” Test the cheapest distinguishing check.
6. **Fix the cause**, smallest change. No drive-by refactors.
7. **Verify** with the `verification` skill (repro that used to fail, plus nearby tests).

Stop after three failed fix attempts: re-investigate; consider architecture. Do not stack unrelated patches.

## Progressive disclosure

- Verification outcomes: `skills/engineering/verification/SKILL.md`
- Full loop: `docs/review-loop.md` (not this skill)

## Verification

Done when the original failure is reproduced as gone **or** the leftover is `UNKNOWN / INCOMPLETE` with what was not run.

## Failure handling

- Cannot reproduce → INCOMPLETE; do not ship a speculative fix as success
- Tools missing → INCOMPLETE
- Looks like a test bug → prove it; do not invert the assertion to go green

## Provenance

ADAPT obra/superpowers systematic-debugging. B3: verification labels, no mandatory failing-test-first.
