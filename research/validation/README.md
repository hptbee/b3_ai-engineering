# Real-world validation v1

**Date:** 2026-09-07  
**Branch:** `cursor/real-world-validation-v1-a097`  
**Method:** description-driven activation (this agent, B3 loaded) + tabletop application of skills to realistic snippets + manual review-loop walkthroughs.

v1 was **not** a live host-loader experiment. v2: Cursor **discovers** the 23 project skills in Customize → Skills after a local `.cursor/skills` junction (`cursor-host-v2.md`). v3: skills/commands/agents/rules live on committed Cursor discovery paths (`cursor-host-v3.md`). Auto-activation and Codex/Claude remain `NOT VERIFIED`.

Do not treat this folder as historical Phase 1 research. It is evidence for the current catalog.

| File | Contents |
| --- | --- |
| [validation-matrix.md](validation-matrix.md) | Tasks V1–V25 |
| [activation-results.md](activation-results.md) | v1 pre-retune description judge |
| [activation-results-v2.md](activation-results-v2.md) | v2 post-retune description judge (not host loader) |
| [cursor-host-v2.md](cursor-host-v2.md) | Cursor discovery: baseline FAIL; project Skills UI **PASS** (23) after `.cursor/skills` junction |
| [cursor-host-v3.md](cursor-host-v3.md) | Layout after decision-009: committed `.cursor/` discovery paths; UI auto-activation **NOT VERIFIED** |
| [composition-results.md](composition-results.md) | Multi-skill stacks |
| [review-loop-results.md](review-loop-results.md) | Four manual loops + two agents |
| [portability-results.md](portability-results.md) | Cursor / Codex / Claude |
| [failures.md](failures.md) | Observed production-like failures |
| [decisions.md](decisions.md) | ADOPT / ADAPT / REJECT / DEFER |
| [scorecard.md](scorecard.md) | Per-skill scorecard |
| [provenance-note.md](provenance-note.md) | Licensing INCOMPLETE; profiles unfilled |

## What was not done

- Eval runner (still deferred)
- New domain skills (no Dapper skill)
- Architecture redesign
- Inferring Tùng’s preferences into `profiles/tung/`
