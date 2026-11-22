# Review loop

| Piece | File | Runtime load |
| --- | --- | --- |
| Procedure | [`strategy.md`](strategy.md) | **Load on `/b3-review-loop` and `/b3-ship` Review** (self-sufficient at runtime) |
| Contract / Sizing / Slots | [`spec.md`](spec.md), [`sizing.md`](sizing.md), [`models.md`](models.md) | **Reference only** — do not load on normal runs unless disambiguating an edge case |
| Two-model (Cursor) | [`../adapters/cursor/review-loop-models.md`](../adapters/cursor/review-loop-models.md) | Optional host `model:` override |
| Invoke / Roles | `commands/b3-review-loop.md`, `agents/*.md` | Entry command & isolated subagent roles |

**Context discipline:**
1. Load `strategy.md` only; sizing thresholds, status aliases, Iteration 2+ `--prev-sha` delta rules, `impl_agent` resume (or standalone `b3-fixer` + `.b3/ship/review-loop/<slug>/` state), `verify-run`/`verify-check` gate, 2-tier circuit breaker, and `SINGLE_AGENT_LIMIT` honesty are inlined there.
2. Run `scripts/b3-guard.{ps1,sh} diff-scope` (`--no-renames`, `NOISE_ONLY`, optional `-PrevSha`/`--prev-sha`) + `mechanical-check` (+ `symbol-check` on refactors, `0 LLM tokens`) before LLM review.
3. Pass file paths + active (`OPEN` / unverified `FIXED`) findings + 1-line `closed:` IDs to subagents; subagents obey strict line caps (`≤ 25` lines Reviewer, `≤ 20` lines Fixer).

Visual diagrams: [`../docs/ship-and-review-guide.md`](../docs/ship-and-review-guide.md).
