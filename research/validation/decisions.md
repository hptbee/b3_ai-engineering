# Validation decisions v1

Evidence: `activation-results.md`, `composition-results.md`, `failures.md`.

| Item | Decision | Why |
| --- | --- | --- |
| Catalog size (19 domain + 4 foundation) | **ADOPT** keep | Overlap is trigger wording, not extra files. No merge. |
| `problem-solving` | **ADAPT** trigger | F1 greedy description |
| `react-hooks` | **ADAPT** trigger | F2 |
| `ef-core` | **ADAPT** trigger | F3; **no Dapper skill** (insufficient evidence of need; fix EF boundary first) |
| `aspnet-core` | **ADAPT** trigger | F4 |
| `simplest-correct` skill + rule | **ADAPT** wording | F5 / Risk 6; rule stays `strong` |
| `debugging` `planning` `refactoring` `testing-strategy` `verification` `code-review` | **ADOPT** | Primaries CORRECT when expected |
| React/Three splits | **ADOPT** | V5–V9, V19–V22 held after noting F2 |
| `api-design` / `api-security` | **ADOPT** | V12 vs V13 split held |
| Commands | **ADOPT** | Thin; no second skill body |
| Two agents | **ADOPT** keep; invocation **DEFER** | Mandates useful on paper; host not tested |
| Workflows | **ADOPT** | Did not replace review-loop spec |
| Eval runner | **DEFER** | Explicit |
| Three-host portability | **DEFER** Codex/Claude | Cursor baseline discovery **FAIL** without `.cursor/skills`; re-check after new chat |
| Description retunes F1–F5 | **ADOPT** on paper | v2 description judge: 24/25 CORRECT; V24 still AMBIGUOUS. Host activation still unproven. |
| Profile fill | **DEFER** | No explicit user confirmation; placeholders stay |
| Remove any skill | **REJECT** removal | NOT_ENOUGH_EVIDENCE to delete |
| New skills | **REJECT** this phase | Including Dapper |
