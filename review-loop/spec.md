# Review loop

The review loop is independent verification plus iterative correction. It answers: **is the implementation actually correct?**

This document is the specification. Orchestration: [`strategy.md`](strategy.md). A single pass of the `code-review` skill is not the loop.

A single invocation of `.cursor/commands/review-loop.md` runs **review → validate → fix → verify → fresh review** until a quality gate, non-convergence, or iteration limit. Do not require the user to re-trigger after each fix.

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
10. Validate findings; fix only valid CONFIRMED items
11. Verify (build / relevant tests)
12. Fresh independent review of the current implementation
13. Stop when the quality gate holds or a termination condition is reached
```

Skip a review dimension only when it is out of scope **and** that skip is recorded. “Not relevant” without a reason is not a skip.

Adaptive path: SMALL/MEDIUM = this loop on the full PR. LARGE/VERY_LARGE = logical review **units**, then a **cross-cutting** review. [`sizing.md`](sizing.md).

## Outcomes

Every check and the loop as a whole must end in one of:

| Outcome | Meaning |
| --- | --- |
| **PASS** | Required evidence was produced and supports the claim |
| **FAIL** | Evidence shows the claim is false, or a confirmed issue remains |
| **UNKNOWN / INCOMPLETE** | Evidence is missing, a tool failed, scope was not covered, or time/iteration ran out |

PASS is never inferred from silence.

## Finding lifecycle

Findings are stateful. They are not a flat bullet list that resets every iteration.

```text
NEW
 ↓
INVESTIGATING
 ├── CONFIRMED
 │      ↓
 │    FIXED
 │      ↓
 │   VERIFIED
 │      ↓
 │    CLOSED
 │
 ├── FALSE_POSITIVE
 │
 └── SPECULATIVE
```

| Status | Meaning |
| --- | --- |
| `NEW` | Reported, not yet examined |
| `INVESTIGATING` | Evidence is being gathered |
| `CONFIRMED` | Evidence supports that the issue exists |
| `FIXED` | A change was made that is intended to address it |
| `VERIFIED` | The verification that would catch it was run and passed |
| `CLOSED` | Done (verified fix, or accepted false positive / out of scope with a reason) |
| `FALSE_POSITIVE` | Investigation showed it is not a real issue |
| `SPECULATIVE` | Too thin to confirm; parked, not blocking |

`FIXED` without `VERIFIED` is not closed. `SPECULATIVE` must not be presented as `CONFIRMED`.

## Finding schema (conceptual)

Runtime may store this as YAML, JSON, or a table. Fields are conceptual; do not require a database.

```yaml
id:
severity:
confidence:
status:
category:
location:
description:
evidence:
suggested_fix:
verification:
```

| Field | Role |
| --- | --- |
| `id` | Stable across iterations |
| `severity` | How harmful **if the issue is real** |
| `confidence` | How sure the reviewer is that it **exists** |
| `status` | Lifecycle value above |
| `category` | See below |
| `location` | File / symbol / surface |
| `description` | What is wrong |
| `evidence` | Why we believe it (required for `CONFIRMED` whenever reasonably possible) |
| `suggested_fix` | Optional, not a mandate to over-scope |
| `verification` | What check would prove the fix |

### Categories

```text
correctness
security
performance
architecture
maintainability
testing
reliability
ux
```

### Severity vs confidence

**Severity** is harm. **Confidence** is certainty that the defect is real.

Suggested severity: `critical`, `high`, `medium`, `low`. Suggested confidence: `high`, `medium`, `low`. Keep these short; do not invent a ten-point scale.

```text
critical + low confidence
```

must **not** automatically be treated as a confirmed critical defect. Investigate or leave `SPECULATIVE` / `INVESTIGATING`. Do not block the world on an ungounded scare, and do not ignore a high-confidence critical with evidence.

Avoid noisy speculative findings. A long list of guesses is a failed review, not a thorough one.

## False-convergence protection

The loop is not done because the latest write-up looks tidy.

### No review target

If the change/diff is empty, the branch is wrong, or the review target cannot be established:

```text
UNKNOWN / INCOMPLETE
```

not PASS.

### Tool failure

If a required test, build, lint, reviewer, or verification tool fails to **run** (unavailable, timeout, missing credential, skipped suite):

```text
UNKNOWN / INCOMPLETE
```

not PASS.

Distinguish:

- **The product failed a real check** → FAIL
- **The check did not run** → UNKNOWN / INCOMPLETE

Never declare success because a tool failed.

### Stagnation

Detect and refuse a fake green:

- the same finding repeating without a material change
- the same fix repeatedly failing verification
- no meaningful code change across an iteration that claimed to fix issues
- identical review result across iterations
- reviewer disagreement without resolution
- stale findings that refer to code no longer present
- repeated tool failures

Any of these → stop, escalate, or mark **INCOMPLETE** — not success.

### Iteration limit

Default **`MAX_ITERATIONS = 5`** for a full-PR (SMALL/MEDIUM) scope. LARGE unit loops use **3** per unit, **2** for cross-cutting, and a **12** cap on total reviewer passes (`review-loop/strategy.md`).

When the maximum is reached:

```text
INCOMPLETE
```

not PASS.

If confirmed issues still remain, the overall outcome may be FAIL **and** incomplete — never PASS because the budget ran out.

Also required: **critical-issue escalation** (do not grind forever on security/data-loss) and **human decision points** (scope too large, values conflict, irreversible change).

### Evidence

Every `CONFIRMED` finding should have evidence whenever reasonably possible. No evidence → do not confirm. Speculative items stay `SPECULATIVE` or are dropped.

When consolidating, drop stale items, merge duplicates, and carry evidence and `id`s forward. Fixes must map to findings. Unrelated cleanup is out of loop scope unless the human expanded scope.

## Quality gate

A scope passes when **critical = 0**, **high = 0**, **medium = 0**, and required build/tests are **PASS**. LOW/NIT may remain and must be listed. Missing tool evidence → `UNKNOWN / INCOMPLETE`, never PASS.

Runtime IDs (`R001`…) and OPEN/FIXED/REJECTED/ACCEPTED/REOPENED aliases: [`findings.md`](findings.md).

## Independence

Implementation and review should not be the same unchecked voice. Three slots: orchestrator (stop/PASS only), reviewer (no edits), fixer (edits + verify, no loop outcome). Optional `security-reviewer` / `architecture-reviewer`. Hosts may assign different models in **host agent config** only (`models.md`) — not in this spec.

## Verification inside the loop

Verification uses the verification skill and the verification rule:

- run the relevant tests, builds, or probes
- record what ran and what did not
- re-verify after fixes (`FIXED` → `VERIFIED` or back to `CONFIRMED`)
- then a **fresh** review of the current implementation (not “confirm the old ID list”)

## Termination

Stop when:

- no in-scope blocking CONFIRMED findings remain (`critical`/`high`/`medium` = 0) **and** required verification is PASS, or
- a termination condition fires (iteration limit, stagnation, escalation, human stop)

Record the stop reason. Do not imply completeness when the stop was a limit. Exhausting the iteration limit is **INCOMPLETE**, not PASS.
