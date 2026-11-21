# Review loop

| Piece | File | Runtime load |
| --- | --- | --- |
| Procedure | [`strategy.md`](strategy.md) | **Load on `/review-loop` and `autodev` Review** (self-sufficient at runtime) |
| Contract / Sizing / Findings / Slots | [`spec.md`](spec.md), [`sizing.md`](sizing.md), [`findings.md`](findings.md), [`models.md`](models.md) | **Reference only** — do not load on normal runs unless disambiguating an edge case |
| Two-model (Cursor) | [`../adapters/cursor/review-loop-models.md`](../adapters/cursor/review-loop-models.md) | Optional host `model:` override |
| State | `state/` (gitignored except [`state/TEMPLATE.md`](state/TEMPLATE.md)) | Optional standalone working log (`autodev` uses `{RUN_DIR}/findings.md` instead) |
| Invoke / Roles | `commands/review-loop.md`, `agents/*.md` | Entry command & isolated subagent roles |

**Context discipline:**
1. Load `strategy.md` only; sizing thresholds, status aliases, and Iteration 2+ `--prev-sha` delta rules are inlined there.
2. Run `scripts/autodev-guard.{ps1,sh} diff-scope` (`--no-renames`, `NOISE_ONLY`, optional `-PrevSha`/`--prev-sha`) to scope files without dumping lockfile noise.
3. Pass file paths + active (`OPEN` / unverified `FIXED`) findings + 1-line `closed:` IDs to subagents; subagents obey strict line caps (`≤ 25` lines Reviewer, `≤ 20` lines Fixer).
