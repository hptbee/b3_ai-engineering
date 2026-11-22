# Review loop

| Piece | File | Runtime load |
| --- | --- | --- |
| Procedure | [`strategy.md`](strategy.md) | **Load on `/review-loop` and `/ship` Review** (self-sufficient at runtime) |
| Contract / Sizing / Findings / Slots | [`spec.md`](spec.md), [`sizing.md`](sizing.md), [`findings.md`](findings.md), [`models.md`](models.md) | **Reference only** — do not load on normal runs unless disambiguating an edge case |
| Two-model (Cursor) | [`../adapters/cursor/review-loop-models.md`](../adapters/cursor/review-loop-models.md) | Optional host `model:` override |
| State | `state/` (gitignored except [`state/TEMPLATE.md`](state/TEMPLATE.md)) | Optional standalone working log (`/ship` uses `{RUN_DIR}/findings.md` instead) |
| Invoke / Roles | `commands/review-loop.md`, `agents/*.md` | Entry command & isolated subagent roles |

**Context discipline:**
1. Load `strategy.md` only; sizing thresholds, status aliases, Iteration 2+ `--prev-sha` delta rules, `impl_agent` resume, and 2-tier circuit breaker are inlined there.
2. Run `scripts/b3-guard.{ps1,sh} diff-scope` (`--no-renames`, `NOISE_ONLY`, optional `-PrevSha`/`--prev-sha`) + `mechanical-check` (`0 LLM tokens`) before LLM review.
3. Pass file paths + active (`OPEN` / unverified `FIXED`) findings + 1-line `closed:` IDs to subagents; subagents obey strict line caps (`≤ 25` lines Reviewer, `≤ 20` lines Fixer).

Visual diagrams: [`../docs/ship-and-review-guide.md`](../docs/ship-and-review-guide.md).
