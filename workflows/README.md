# Workflows

Workflows are multi-step orchestration. They answer: **in what order should things happen?**

**Status:** present (default product sequence, plus full `/ship` lifecycle). Independent review is not a third workflow file — it is `review-loop/` invoked by `commands/review-loop.md` and `/ship`.

| Workflow | Sequence |
| --- | --- |
| [`feature-implementation.md`](feature-implementation.md) | `Scope → Plan → Build → Verify → Review → Fix → Verify` |
| [`ship.md`](ship.md) | `Preflight → Plan → [Scope → Gate → Build → Verify → Guard → Review → Fix → Commit] → Finalize` |

Progressive-disclosure references for `/ship` (opened only on template creation or `resume`):
- [`references/ship-templates.md`](references/ship-templates.md) — `master-plan.md` (`Shared contracts`), `progress.md` (`impl_agent`), and `approach/T00N.md` schemas
- [`references/ship-resume.md`](references/ship-resume.md) — Scenario C Git-verified resume and freshness protocol
- Deterministic helper CLI (not an orchestrator): [`../scripts/README.md`](../scripts/README.md) (`b3-guard.{ps1,sh}`)
- Visual diagrams & walkthrough: [`../docs/ship-and-review-guide.md`](../docs/ship-and-review-guide.md)

Single-pass review remains `commands/review.md`. Full loop: `commands/review-loop.md`. Full lifecycle: `commands/ship.md`.
