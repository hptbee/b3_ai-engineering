# Review loop

| Piece | File | Runtime load |
| --- | --- | --- |
| Procedure | [`strategy.md`](strategy.md) | **Load on `/b3-review-loop` and `/b3-ship` Review** (self-sufficient for `XS`/`S`/`M`) |
| Large / XXL | [`hierarchical.md`](hierarchical.md) | **Load on demand only** when `size_class` is `L`, `XL`, or `XXL` (`0` B for `XS`/`S`/`M`) |
| Contract / Sizing / Slots | [`spec.md`](spec.md), [`sizing.md`](sizing.md), [`models.md`](models.md) | **Reference only** — do not load on normal runs unless disambiguating an edge case |
| Two-model / `model:` overrides (Cursor) | [`../adapters/cursor/README.md`](../adapters/cursor/README.md) | Optional host `model:` override |
| Invoke / Roles | `commands/b3-review-loop.md`, `agents/*.md` | Entry command & isolated subagent roles |

**Context discipline:**
1. Load `strategy.md` only (`hierarchical.md` added only on `L`/`XL`/`XXL`); 6 T-shirt sizes + decoupled `risk_level`, legacy normalization (`b3 guard review-ledger --action normalize`), Iteration 2+ `--prev-sha` delta rules, `impl_agent` resume, `verify-run`/`verify-check` & `review-ledger --action check` gates, 2-tier circuit breaker, and `SINGLE_AGENT_LIMIT` honesty live there.
2. Run `b3 guard diff-scope` (plus `review-inventory` on `L`/`XL`/`XXL`), `mechanical-check`, and `symbol-check` (`0 LLM tokens`) before LLM review.
3. Pass file paths + active (`OPEN` / unverified `FIXED`) findings + 1-line `closed:` IDs to subagents; subagents obey strict line caps (`≤ 25` lines Reviewer, `≤ 20` lines Fixer).

Visual diagrams: [`../docs/ship-and-review-guide.md`](../docs/ship-and-review-guide.md).
