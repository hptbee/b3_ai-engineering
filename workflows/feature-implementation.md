# Feature implementation

Default product-work sequence. Does not replace skills. Does not replace `docs/review-loop.md`.

```text
Understand → Plan → Implement → Verify → Review → Fix → Re-verify
```

| Step | Use |
| --- | --- |
| Understand | Read code and constraints |
| Plan | `skills/engineering/planning` when multi-step; else a short plan in-place |
| Implement | `problem-solving` + smallest domain skill |
| Verify | `verification` |
| Review | `code-review` (one pass) |
| Fix / Re-verify | map fixes to findings; run checks again |

Independent multi-iteration review: `workflows/independent-review.md`.

Architecture choices: `simplest-correct` (strong rule `rules/simplest-correct.md`).
