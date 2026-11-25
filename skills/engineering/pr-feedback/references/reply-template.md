# PR Feedback Templates

Concise, natural US English templates for `b3-pr-reply`, `b3-pr-resolve`, and `b3-pr-comment`.

Canonical severity vocabulary (`CRITICAL`, `HIGH`, `MEDIUM`, `LOW`), verdicts (`PASS`, `CHANGES_NEEDED`, `UNKNOWN / INCOMPLETE`), and evidence rules are owned by [`skills/engineering/code-review/references/review-template.md`](../../code-review/references/review-template.md). Omit empty placeholders and boilerplate. Never invent commit SHAs, verification commands, or results.

---

## Reply — Fixed

```markdown
Fixed in `<commit SHA>`.

<Concise explanation of the change.>

Verification: `<actual executed check and result>`.
```

## Reply — Already Fixed

```markdown
This is already addressed in `<commit SHA or current code reference>`.

<Brief supporting evidence.>
```

## Reply — Disagreement

```markdown
I checked `<relevant implementation or contract>`.

<Concise technical explanation supported by evidence.>

<Optional clarification or recommendation.>
```

## Reply — Clarification

```markdown
Could you clarify `<specific expected behavior>`?

<Brief explanation of the ambiguity or contract impact.>
```

## Reply — Duplicate

```markdown
Tracked with `<primary thread or root-cause reference>` and addressed in `<commit SHA or current status>`.

<Brief confirmation that this instance shares the same root cause.>
```

## Reply — Blocked

```markdown
Blocked on `<specific missing permission, verification gate, external dependency, or governance decision>`.

<What was checked and what is needed to proceed.>
```

---

## Inline Review Comment

Post ONLY `CONFIRMED` findings backed by concrete evidence. Use strictly `CRITICAL`, `HIGH`, `MEDIUM`, or `LOW`.

```markdown
**[HIGH] — <Short issue title>**

<Problem, violated invariant, and practical impact.>

**Suggested fix:** <Minimal actionable recommendation.>
```

---

## Review Summary

When inline findings are posted alongside the summary (`both` mode), do **not** repeat full inline descriptions in the summary — summarize counts, verdict, verification, and cross-cutting risk only. Omit `**Not verified:**` if everything in scope was verified.

```markdown
## Review Summary

**Verdict:** `<PASS | CHANGES_NEEDED | UNKNOWN / INCOMPLETE>`

**Reviewed commit:** `<SHA>`

**Findings:** Critical: N | High: N | Medium: N | Low: N

<Concise overall assessment.>

**Verification:** <Actual checks and results>

**Not verified:** <Remaining limitations, if any>
```

---

## General PR Comment Reference & Idempotency Marker (Adapter-Managed)

- When replying to a top-level general PR comment (`general_comment`), prepend a concise permalink/reference line (`> Replying to [comment #<id>](<html_url>)`) unless the body already cites it.
- The SCM adapter appends a stable operation-identity HTML comment (`<!-- b3-pr-key:<key>;op=<16hex> -->`) on the final line for actor-scoped deduplication and collision detection while keeping rendered Markdown clean.
