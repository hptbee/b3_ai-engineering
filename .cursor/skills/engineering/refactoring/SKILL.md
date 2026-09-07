---
name: refactoring
description: >
  Use when changing structure without intended behavior change: extract,
  rename, split modules, reduce duplication. Do not use for features,
  bugfixes that must change behavior, or performance work that changes
  timing contracts.
---

# Refactoring

Behavior-preserving change. If behavior should change, it is not this skill.

## When to use

- Unwieldy file, duplicated logic, unclear names
- Preparing a seam for a later feature
- User asks to clean up without new features

## When not to use

- New product behavior → `problem-solving`
- “Make it faster” → performance skills
- Review-only → `code-review`

Near miss: “refactor and add validation” is two jobs — split; validation is behavior.

## Procedure

1. **Characterize current behavior** (tests, probes, or explicit INCOMPLETE).
2. **Smallest structural change** that improves the named problem.
3. **Do not** mix feature work, dependency upgrades, or formatting-only dumps.
4. **Keep public contracts** unless the user expanded scope.
5. **Re-run** the characterization checks (`verification`).

## Verification

Refactor is done when the same checks still pass (or INCOMPLETE if they could not run). Silent “looks equivalent” is not enough.

## Failure handling

- No tests and cannot characterize → INCOMPLETE; do not large-rewrite
- Behavior accidentally changed → treat as bug; `debugging`

## Provenance

B3 engineering principles (smallest change). Superpowers TDD refactor step observed, not copied.
