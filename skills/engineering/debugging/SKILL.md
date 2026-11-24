---
name: debugging
description: >
  Use when a bug, test failure, or regression needs root-cause
  investigation before patching (before guessing a fix). Not for
  greenfield features, known-good diff reviews, or claiming tests passed.
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
4. **Locate the broken boundary & invariant:** after repro/logs/recent diff, read known targets directly or load `workflows/references/context-routing.md` on demand (optional `serena`/`codebase-memory` for boundary/symbol tracing; native fallback on MCP failure). Find the failing boundary (client/server, middleware/handler, query/app) and name the **explicit broken invariant** before changing code. Add a probe only if needed.
5. **One hypothesis:** “X causes Y because invariant Z breaks.” Run the cheapest distinguishing check.
6. **Fix cause + proportional bug-class sweep:** apply the smallest root-cause patch restoring the invariant. Inspect **affected callers and sibling entry points** strictly supported by the same broken invariant; fix confirmed sibling occurrences only within requested scope (no speculative repo-wide scans or drive-by refactors).
7. **Verify & anti-symptom check:** add/update a **regression test** for the original failure (or exact repro probe if no harness exists), verify the invariant itself holds (not error-swallowing or relaxed assertions), and confirm via `verification` skill (`b3-guard verify-run` for non-trivial fixes).

Stop after **3 failed fix attempts**: record each disproved hypothesis + observed evidence, stop stacking patches, and escalate to architecture/design re-investigation or report `INCOMPLETE`/`BLOCKED`.

## Progressive disclosure

- Context routing (on demand): `workflows/references/context-routing.md`
- Verification outcomes: `skills/engineering/verification/SKILL.md`
- Full loop: `review-loop/strategy.md` (not this skill)

## Verification

Done when the original failure is reproduced as gone **or** the leftover is `UNKNOWN / INCOMPLETE` with what was not run.

## Failure handling

- Cannot reproduce → INCOMPLETE; do not ship a speculative fix as success
- Tools missing → INCOMPLETE
- Looks like a test bug → prove it; do not invert the assertion to go green

## Provenance

ADAPT obra/superpowers systematic-debugging. B3: verification labels, no mandatory failing-test-first.
