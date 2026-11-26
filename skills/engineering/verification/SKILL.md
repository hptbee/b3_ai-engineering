---
name: verification
description: Use when claiming work passes, finishing fixes/review loops, or confirming tests, builds, or behavior with executed evidence. Not for design-only discussion or writing tests without running them.
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

1. **Name the claim & scope** in one sentence (exact behavior + acceptance criteria / paths).
2. **Name the evidence** that confirms it (command, probe, test scope, and relevant dependency manifests/configs).
3. **Run & record provenance:** execute cleanly via `b3 guard verify-run` (writes reusable `b3-verify-v1` receipt at `.b3/ship/verify/<slug>.verify` capturing `HEAD`, `tree_hash`, `command`, `exit_code`, `log_path`, `timestamp_utc`) or direct tool execution when CLI guards are unavailable. Include dependency manifests/lockfiles/configs in `--relevant-paths` (or omit for `ALL`) so dep/config changes invalidate stale receipts. Parallelize independent verification commands only when build dirs, DBs, ports, and temp paths are conflict-free (`SHARED_READ_ONLY` per `workflows/references/dispatch-naming.md`), preserving exact exit codes and receipts.
4. **Validate before reusing evidence:** never trust an agent-written receipt or log summary without running `b3 guard verify-check --expected-cmd ... --relevant-paths ...` (`VERIFY_VALID` exit `0`). On untrusted provenance, `VERIFY_STALE`, `VERIFY_MISMATCH`, `VERIFY_SCOPE_MISMATCH`, or `VERIFY_CORRUPT`, re-run checks on the current working tree.
5. **Map result to outcome:**
   - executed evidence supports claim on current tree → `PASS`
   - executed evidence contradicts claim → `FAIL`
   - evidence missing/untrusted, tool failed, skipped, timed out, or wrong env → `UNKNOWN / INCOMPLETE`
6. **After a fix**, re-run the evidence that would have caught the issue against current tree (`verify-run` / `verify-check`).
7. **Report compactly:** claim, source revision (`HEAD` + `tree_hash`/receipt path), command/probe, exit code, scope/AC coverage, log ref, and outcome (naming any skipped/timed-out/unavailable checks). Do **not** upgrade incomplete/unmeasured speed or correctness claims to `PASS`.

## Progressive disclosure

- Hard constraints: `rules/verification.md`
- Review-loop use of outcomes: `review-loop/strategy.md`

## Verification of this skill

This skill is applied correctly when the write-up lists what ran, what did not, and the outcome label. A summary with no commands, no results, and a success claim is a failed use of the skill.

## Failure handling

- No test runner / no browser / no network → `UNKNOWN / INCOMPLETE` plus the blocker
- Flaky or inconclusive run → do not call PASS; rerun or mark incomplete
- Wrong environment (cannot exercise the change) → incomplete, not a skip disguised as success
- User asks to “just say it works” → refuse; report the actual outcome
