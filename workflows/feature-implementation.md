# Feature implementation

Default product-work sequence. Does not replace skills or `review-loop/strategy.md`.

```text
Scope → Plan → Build → Verify → Review → Fix → Verify
```

| Step | Use |
| --- | --- |
| Scope | Read known targets directly (short-circuit) or load [`references/context-routing.md`](references/context-routing.md) on demand for unfamiliar architecture/symbols (optional MCP acceleration, native fallback); inspect callers and constraints |
| Plan | `skills/engineering/planning` when multi-step; else a short plan in-place |
| Build | `problem-solving` + smallest domain skill (`XS`+`inline` runs inline when `implementation` model in `.b3/models.md` is unset/`auto` or matches `main`; multi-slice work validates disjoint impl/test/doc slices via `b3 guard check-wave --partition` and dispatches `b3-impl-t00N` per [`references/dispatch-naming.md`](references/dispatch-naming.md)) |
| Verify | `verification` (executed checks; `b3 guard verify-run` for non-trivial changes/handoffs) |
| Review | `b3 guard diff-scope` + `mechanical-check` (+ `symbol-check` on refactors) → diff-first, risk-sensitive `code-review` (concurrent `SHARED_READ_ONLY` `b3-reviewer` + triggered specialists on high risk; optional [`references/context-routing.md`](references/context-routing.md) on demand with native fallback) |
| Fix / Verify | Fix root causes, add regression tests, remove `CONFIRMED` residue, re-verify (max 2 bounded rounds) |

During **Review**, do not only ask "is it correct?" Also ask: *given final requirements, is all of this code still necessary?* Remove temporary scaffolding, dead branches, and redundant state.

Independent multi-iteration loop: `commands/b3-review-loop.md` → `review-loop/strategy.md`. `/b3-implement` uses the one-pass review here and does not start the review loop.

[`ship.md`](ship.md) reuses `Scope`, `Plan`, `Build`, and `Verify` with Just-in-Time `Scope` + `Gate` (Implementation Readiness Gate). Post-code review is risk-tiered: 1 fresh `b3-reviewer` pass **only** on `inline` + `XS`/`S` + `LOW`-risk tasks (escalating to the loop on any confirmed blocker); full `review-loop` on `>=M`, `>=MEDIUM` risk, `notes`/`detailed` tasks, and `Finalize`. Ready tasks continue without stopping between Gate and Build or between tasks.

Architecture choices: `simplest-correct` (`rules/simplest-correct.md`).
