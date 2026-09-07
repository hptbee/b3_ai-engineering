# Finding log

Use the schema in [`spec.md`](spec.md). Runtime IDs are stable across iterations:

```text
R001, R002, R003, …
```

Never recycle an ID for a different issue. New issues get the next ID.

## Status aliases

Orchestrator logs may use short names. Map onto the spec lifecycle:

| Runtime (user-facing) | Spec status |
| --- | --- |
| `OPEN` | `CONFIRMED` (blocking) or `NEW`/`INVESTIGATING` while validating |
| `FIXED` | `FIXED` (not closed until verified) |
| `REJECTED` | `FALSE_POSITIVE` |
| `ACCEPTED` | `CLOSED` with reason (out of scope / intentional) |
| `REOPENED` | back to `CONFIRMED` **only with new evidence** the fix failed or was undone |

`SPECULATIVE` stays speculative — not OPEN for the quality gate.

`FIXED` without verification evidence stays non-CLOSED (`spec.md`).

## Iteration log (required)

```text
Scope: full-pr | unit:<name> | cross-cut
Iteration 1: OPEN blocking=8  (R001 HIGH …)
Iteration 2: OPEN blocking=3  R001 FIXED/VERIFIED …
…
```

Do not reopen CLOSED/REJECTED/ACCEPTED unless evidence shows the defect still exists.

## Optional working file

Session table is enough. If writing to disk, use `review-loop/state/current.yaml` (gitignored). Shape:

```yaml
target: origin/main...HEAD
size: LARGE
max_iterations: 5
iteration: 2
findings:
  - id: R001
    severity: high
    confidence: high
    status: FIXED
    category: correctness
    location: src/orders/get.ts
    description: ...
    evidence: ...
    suggested_fix: ...
    verification: ...
```
