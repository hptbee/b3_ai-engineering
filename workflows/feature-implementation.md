# Feature implementation

Default product-work sequence. Does not replace skills or `review-loop/strategy.md`.

```text
Scope → Plan → Build → Verify → Review → Fix → Verify
```

| Step | Use |
| --- | --- |
| Scope | Read known targets directly (short-circuit) or load [`references/context-routing.md`](references/context-routing.md) on demand for unfamiliar architecture/symbols (optional MCP acceleration, native fallback); inspect callers, constraints, and apply proportional clarity check ([`references/clarification-gate.md`](references/clarification-gate.md) on demand for non-trivial/ambiguous work) |
| Plan | `skills/engineering/planning` when multi-step; else a short plan in-place |
| Build | `problem-solving` + smallest domain skill (`XS`+`inline` runs inline when `implementation` model in `.b3/config.toml` is unset/`auto` or matches `main`; multi-slice work validates disjoint impl/test/doc slices via `b3 guard check-wave --partition` and dispatches `b3-impl-t00N` per [`references/dispatch-naming.md`](references/dispatch-naming.md)) |
| Verify | `verification` + [`references/static-analysis.md`](references/static-analysis.md) (Parent-once native discovery, scoped safe auto-fixes before `verify-run`, baseline attribution vs `PREEXISTING_BASELINE`) |
| Review | Run deterministic checks (`b3 guard diff-scope` + `mechanical-check` + native lint, plus `symbol-check` on refactors or native coverage gaps) before AI review (`static-analysis.md` digest) → diff-first, risk-sensitive `code-review` (concurrent `SHARED_READ_ONLY` `b3-reviewer` + triggered specialists on high risk; optional [`references/context-routing.md`](references/context-routing.md) on demand with native fallback) |
| Fix / Verify | Fix root causes, add regression tests, remove `CONFIRMED REDUNDANCY` / evidenced `CONFIRMED` overengineering (concrete simpler alt meeting all reqs, never LOC alone; leave `SPECULATIVE`/`INTENTIONAL COMPLEXITY`/`UNKNOWN`), re-verify (max 2 bounded rounds) |

During **Review**, do not only ask "is it correct?" Also ask: *given final requirements, is all of this code still necessary?* Remove `CONFIRMED REDUNDANCY` (local diff via `code-review`/`b3-reviewer`; system shape via `simplest-correct`/`b3-architecture-reviewer`) and preserve `INTENTIONAL COMPLEXITY`.

Independent multi-iteration loop: `commands/b3-review-loop.md` → `review-loop/strategy.md`. `/b3-implement` uses the one-pass review here and does not start the review loop.

[`ship.md`](ship.md) reuses `Scope`, `Plan`, `Build`, and `Verify` with Just-in-Time `Scope` + `Gate` (Implementation Readiness Gate). Post-code review is risk-tiered: 1 fresh `b3-reviewer` pass **only** on `inline` + `XS`/`S` + `LOW`-risk tasks (escalating to the loop on any confirmed blocker); full `review-loop` on `>=M`, `>=MEDIUM` risk, `notes`/`detailed` tasks, and `Finalize`. Ready tasks continue without stopping between Gate and Build or between tasks.

Architecture choices: `simplest-correct` (`rules/simplest-correct.md`).
