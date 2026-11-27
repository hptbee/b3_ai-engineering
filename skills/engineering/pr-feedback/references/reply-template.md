# PR Feedback Templates

Concise, natural US English PR reply, inline comment, and review summary templates. Keep posted PR replies, comments, and reviews tool-neutral: never include `b3`/`B3` keywords or a `Verification` section.

Canonical severity vocabulary (`CRITICAL`, `HIGH`, `MEDIUM`, `LOW`), verdicts (`PASS`, `CHANGES_NEEDED`, `UNKNOWN / INCOMPLETE`), and evidence rules are owned by [`skills/engineering/code-review/references/review-template.md`](../../code-review/references/review-template.md). Omit empty placeholders and boilerplate. Never invent commit SHAs, verification commands, or results.

---

## Reply — Fixed

```markdown
Fixed in `<commit SHA>`.

<Concise explanation of the change.>
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

## Review Summary (`b3-pr-comment`, `b3-review --post`)

Use the canonical [`## Review Summary` format in `review-template.md`](../../code-review/references/review-template.md) (include **`Reviewed commit:`** `<SHA>` in metadata). In `both` mode, omit full inline finding descriptions from the summary — keep counts, verdict, and cross-cutting risk only. Omit `## Speculative / Questions for Author` and unverified placeholders when posting `CONFIRMED` PR reviews.

---

## General PR Comment Reference & Idempotency Marker (Adapter-Managed)

- When replying to a top-level general PR comment (`general_comment`), prepend a concise permalink/reference line (`> Replying to [comment #<id>](<html_url>)`) unless the body already cites it.
- The SCM adapter appends a stable operation-identity HTML comment (`<!-- pr-key:<key>;op=<16hex> -->`) on the final line for actor-scoped deduplication and collision detection while keeping rendered Markdown clean.
