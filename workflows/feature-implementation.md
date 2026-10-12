# Feature implementation

Default product-work sequence. Does not replace skills. Does not replace `review-loop/spec.md`.

```text
Understand → Plan → Implement → Verify → Review → Fix → Re-verify
```

| Step | Use |
| --- | --- |
| Understand | Read code and constraints |
| Plan | `.cursor/skills/engineering/planning` when multi-step; else a short plan in-place |
| Implement | `problem-solving` + smallest domain skill |
| Verify | `verification` |
| Review | `code-review` (one pass: correctness, security, performance, simplification/residue check) |
| Fix / Re-verify | map fixes to findings; remove confirmed residue; run checks again |

During the **Review** step, do not only ask "is it correct?" Also ask: *given the final implementation and current requirements, is all of this code still necessary?* Check whether intermediate implementation steps left behind temporary scaffolding, dead branches, or redundant state.

Independent multi-iteration review: `.cursor/commands/review-loop.md` → `review-loop/strategy.md`.

`/implement` uses the one-pass review in this file and does not start the review loop.

[`autonomous-development.md`](autonomous-development.md) uses the understand, plan, implement, and verify steps here, then the review loop instead of this one-pass review, and it does not stop between tasks.

Architecture choices: `simplest-correct` (strong rule `rules/simplest-correct.md`).
