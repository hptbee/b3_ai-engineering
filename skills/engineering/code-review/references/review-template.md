# Shared code review & PR review output template (on-demand)

Single canonical output contract for **both** local `/b3-review` and GitHub PR `/b3-review #<id>` (chat reports and GitHub summary comments). Load **only** when rendering a review; never load into always-on sessions.

## Fixed vocabulary (strict — never improvise synonyms)

- **Severity (4 levels only):** `CRITICAL` | `HIGH` | `MEDIUM` | `LOW`
  - **Never** substitute `Must/Should/Could/Nit`, `P0/P1/P2`, `Blocker/Major/Minor`, or ad-hoc labels.
- **Confidence (separate from Severity):** `HIGH` | `MEDIUM` | `LOW`
- **Status:** `CONFIRMED` (reproduced/proven with concrete `file:line` + invariant evidence) | `SPECULATIVE` (unproven/hypothesis supporting full `CRITICAL | HIGH | MEDIUM | LOW` severity — **chat-only**, never blocking until confirmed and never posted as a PR finding)
- **Verdict:** `PASS` | `CHANGES_NEEDED` | `UNKNOWN / INCOMPLETE`
  - `CHANGES_NEEDED`: at least one `CONFIRMED` finding with severity `CRITICAL`, `HIGH`, or `MEDIUM`.
  - `PASS`: `0` blocking `CONFIRMED` findings (`LOW` does not block `PASS`) and all required checks `PASS`.
  - `UNKNOWN / INCOMPLETE`: missing required evidence, empty target, or failed tool/check (never `PASS`).
  - GitHub submission event defaults to `COMMENT` per [`github-pr-review.md`](github-pr-review.md) unless explicitly instructed otherwise by the user.

## Report template (local diff & PR chat / summary comment)

When posting to a GitHub PR after user confirmation, include **only `CONFIRMED` findings** and omit `## Speculative / Questions for Author` unless concrete clarification questions exist (`SPECULATIVE` guesses stay in chat only).

````markdown
## Review Summary

- **Verdict:** `PASS` | `CHANGES_NEEDED` | `UNKNOWN / INCOMPLETE`
- **Target / Scope:** `<local diff/branch or PR #id>` (`<XS|S|M|L|XL|XXL>`, risk `<LOW|MEDIUM|HIGH|CRITICAL>`, base `<base_sha>`, reviewed `<N>` files; excluded noise `<list or none>`)
- **Severity Breakdown (CONFIRMED):** `CRITICAL: 0 | HIGH: 0 | MEDIUM: 0 | LOW: 0`
- **Notes:** <1–2 sentences summarizing key risk, overall health, or blocker>

## Findings (CONFIRMED)

| ID | Severity | Confidence | Category | Location | Issue & Evidence | Recommended Fix |
| --- | --- | --- | --- | --- | --- | --- |
| R001 | HIGH | HIGH | correctness | `path/to/file.ext:42` | <violated invariant + concrete evidence + sibling caller check> | <minimal, verifiable fix> |

*(If zero confirmed defects: replace table with `None — 0 CONFIRMED findings across checked dimensions.`)*

## Speculative / Questions for Author

<!-- Chat-only for speculative concerns (non-blocking). Omit SPECULATIVE items when posting to GitHub PR. -->
- None (or `SPECULATIVE [CRITICAL|HIGH|MEDIUM|LOW] path/to/file.ext:line — <concern + what check would confirm or refute>`).

## Verification & Coverage

- **Executed checks:** `<command>` -> PASS / FAIL (`<exit code / counts>`), or `None run`
- **Dimensions checked:** correctness, architecture, security, performance, simplification/residue, tests
- **Skipped / Unverified (`UNKNOWN / INCOMPLETE`):** <skipped dimensions with reason, or `None`>
````

## Inline GitHub PR comment format (`Files changed` tab)

For line-level comments via `gh api .../pulls/<id>/reviews --input <tmp.json>`, use the exact fixed severity prefix:

```text
**[CRITICAL|HIGH|MEDIUM|LOW] (`R00N`, `<category>`)** <issue + violated invariant + evidence>. **Fix:** <recommended fix>.
```
