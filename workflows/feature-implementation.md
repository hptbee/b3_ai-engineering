# Feature implementation

Default product-work sequence. Does not replace skills. Does not replace `review-loop/strategy.md`.

```text
Scope → Plan → Build → Verify → Review → Fix → Verify
```

| Step | Use |
| --- | --- |
| Scope | Read code, callers, and constraints |
| Plan | `skills/engineering/planning` when multi-step; else a short plan in-place |
| Build | `problem-solving` + smallest domain skill |
| Verify | `verification` |
| Review | `code-review` (one pass: correctness, security, performance, simplification/residue check) |
| Fix / Verify | Map fixes to findings; remove confirmed residue; run checks again |

During **Review**, do not only ask "is it correct?" Also ask: *given final requirements, is all of this code still necessary?* Check whether intermediate steps left temporary scaffolding, dead branches, or redundant state.

Independent multi-iteration loop: `commands/review-loop.md` → `review-loop/strategy.md`.

`/implement` uses the one-pass review here and does not start the review loop.

[`ship.md`](ship.md) uses `Scope`, `Plan`, `Build`, and `Verify`. Per-task scoping uses Just-in-Time `Scope` plus `Gate` (Implementation Readiness Gate) in that file; post-code checking is risk-tiered (1 independent reviewer pass on small `inline` tasks unless a confirmed finding triggers the loop; full `review-loop` on `notes`/`detailed` tasks and `Finalize`). It continues across ready tasks without stopping between Gate and Build, or between tasks.

Architecture choices: `simplest-correct` (strong rule `rules/simplest-correct.md`).
