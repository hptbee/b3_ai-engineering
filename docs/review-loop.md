# Review loop

The review loop is independent verification plus iterative correction. It answers: **is the implementation actually correct?**

This document is the specification. Runtime reviewers, orchestration, and termination machinery are **not implemented yet**. Future files will live under `review-loop/`.

A single pass of the `code-review` skill is not the loop. The loop repeats review, fix, and verify until the change is clean or a termination condition is hit.

## Default sequence

```text
1.  Define review scope
2.  Understand the change
3.  Review architecture
4.  Review correctness
5.  Review security
6.  Review performance
7.  Review tests
8.  Review maintainability
9.  Consolidate findings
10. Fix actionable findings
11. Verify
12. Re-review affected areas
13. Stop when clean or a termination condition is reached
```

Skip a review dimension only when it is out of scope **and** that skip is recorded. “Not relevant” without a reason is not a skip.

## Outcomes

Every check and the loop as a whole must end in one of:

| Outcome | Meaning |
| --- | --- |
| **PASS** | Required evidence was produced and supports the claim |
| **FAIL** | Evidence shows the claim is false, or a confirmed issue remains |
| **UNKNOWN / INCOMPLETE** | Evidence is missing, a tool failed, scope was not covered, or time/iteration ran out |

PASS is never inferred from silence.

## Safeguard: never declare success because a tool failed

A failed test, unavailable tool, timeout, missing credential, skipped suite, or incomplete review is:

```text
UNKNOWN / INCOMPLETE
```

It is not PASS. It is also not automatically FAIL unless the failure *is* the evidence (for example a test that ran and asserted incorrectly). Distinguish:

- **The product failed a real check** → FAIL
- **The check did not run** → UNKNOWN / INCOMPLETE

## Safeguard: avoid false convergence

The loop is not done merely because the latest write-up looks tidy. Detect at least:

- the same finding repeating without a material change
- stale findings that refer to code no longer present
- no meaningful review target (empty diff, wrong branch, unrelated files)
- implementation unchanged across an iteration that claimed to fix issues
- reviewer disagreement that was papered over rather than resolved
- repeated tool failures

Any of these is a signal to stop, escalate, or mark INCOMPLETE — not to declare success.

## Iteration limits

The loop must have:

- a **maximum iteration** count (implementation will set a default; exhausting it is not success)
- **stagnation detection** (no progress on findings or on evidence)
- **critical-issue escalation** (security, data loss, auth bypass — do not grind forever)
- **human decision points** (scope too large, values conflict, irreversible change)

Exhausting the iteration limit = **UNKNOWN / INCOMPLETE** (or FAIL if confirmed issues remain). It is not PASS.

## Evidence-based findings

Reviewers must grade confidence:

| Grade | Use when |
| --- | --- |
| **Confirmed issue** | Reproduced, traced to code, or contradicted by spec/tests with evidence |
| **Likely issue** | Strong reasoning plus partial evidence |
| **Potential concern** | Plausible and in scope, but not demonstrated |
| **Speculative concern** | Thin; usually omit or park, do not block on it |

Avoid noisy speculative findings. A long list of guesses is a failed review, not a thorough one.

When consolidating, drop stale items, merge duplicates, and carry evidence forward. Fixes must map to findings. Unrelated cleanup is out of loop scope unless the human expanded scope.

## Independence

Implementation and review should not be the same unchecked voice. When specialized agents exist, architecture, security, performance, test, and UX review should be able to run as separate roles. Until then, the loop still requires a distinct review pass after implementation, not a self-congratulation paragraph.

## Verification inside the loop

Verification uses the verification skill and the verification rule:

- run the relevant tests, builds, or probes
- record what ran and what did not
- re-verify after fixes
- re-review only the affected areas plus any contract the fix could have broken

## Termination

Stop when:

- no confirmed or likely in-scope issues remain **and** required verification is PASS, or
- a termination condition fires (iteration limit, stagnation, escalation, human stop)

Record the stop reason. Do not imply completeness when the stop was a limit.
