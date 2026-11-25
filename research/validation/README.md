# Real-world validation & pilot provenance

> **Historical framing:** Individual validation records (`v1`–`v3`, `autodev-v1`/`v2`, `codex-host-v1`, `research-ship-pilot-notes.md`) preserve point-in-time evidence and boundary validations without rewriting past runs. Current canonical layout uses host-neutral root directories per [../decisions/decision-013-host-neutral-multi-host-layout.md](../decisions/decision-013-host-neutral-multi-host-layout.md) (`24` canonical skills + `11` command-skills = `35` `SKILL.md` files, `11` commands, and `299` YAML eval fixtures).

**Initial date:** 2026-09-07  
**Branch:** `cursor/real-world-validation-v1-a097`  
**Method:** description-driven activation (this agent, B3 loaded) + tabletop application of skills to realistic snippets + manual review-loop and lifecycle walkthroughs.

v1 was **not** a live host-loader experiment. v2: Cursor **discovers** the initial 23 project skills in Customize → Skills after a local `.cursor/skills` junction (`cursor-host-v2.md`). v3: skills/commands/agents/rules lived on committed Cursor discovery paths (`cursor-host-v3.md`, later superseded by host-neutral root + `sync-skills` in decision-013). Live UI auto-activation across hosts remains `NOT VERIFIED`.

| File | Contents |
| --- | --- |
| [validation-matrix.md](validation-matrix.md) | Tasks V1–V25 |
| [activation-results.md](activation-results.md) | v1 pre-retune description judge |
| [activation-results-v2.md](activation-results-v2.md) | v2 post-retune description judge (not host loader) |
| [cursor-host-v2.md](cursor-host-v2.md) | Cursor discovery: baseline FAIL; project Skills UI **PASS** (23 initial skills) after `.cursor/skills` junction |
| [cursor-host-v3.md](cursor-host-v3.md) | Historical layout after decision-009 (superseded by decision-013); UI auto-activation **NOT VERIFIED** |
| [codex-host-v1.md](codex-host-v1.md) | Historical Codex host discovery & command-routing validation notes |
| [autodev-v1.md](autodev-v1.md) | Historical `/autodev` v1 lifecycle walkthrough (superseded by `/b3-ship`) |
| [autodev-v2.md](autodev-v2.md) | Historical `/autodev` v2 hardening & guard validation notes (superseded by `/b3-ship`) |
| [research-ship-pilot-notes.md](research-ship-pilot-notes.md) | Sanitized historical `/b3-research-ship` external-pilot boundary & governance validation notes (relocated from `docs/research-ship-tuvi-pilot.md`) |
| [composition-results.md](composition-results.md) | Multi-skill stacks |
| [review-loop-results.md](review-loop-results.md) | Four manual loops + two agents (**tabletop v1**; current procedure is `review-loop/strategy.md`) |
| [portability-results.md](portability-results.md) | Cursor / Codex / Claude |
| [failures.md](failures.md) | Observed production-like failures |
| [decisions.md](decisions.md) | ADOPT / ADAPT / REJECT / DEFER |
| [scorecard.md](scorecard.md) | Per-skill scorecard |
| [provenance-note.md](provenance-note.md) | Licensing INCOMPLETE; profiles unfilled |

## What was not done

- Automated LLM eval runner (still deferred)
- New domain skills beyond the synthesized catalog (no Dapper skill; `pr-feedback` added in engineering catalog via PR #32)
- Inferring Tùng’s preferences into `profiles/tung/`
- Live UI host subagent isolation proof across all 4 hosts (still `NOT VERIFIED`)
