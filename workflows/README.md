# Workflows

Workflows are multi-step orchestration. They answer: **in what order should things happen?**

**Status:** present (default product sequence, plus one autonomous lifecycle). Independent review is not a third workflow file — it is `review-loop/` invoked by `commands/review-loop.md` and by autonomous development.

| Workflow | Sequence |
| --- | --- |
| [`feature-implementation.md`](feature-implementation.md) | Understand → Plan → Implement → Verify → Review → Fix → Re-verify |
| [`autonomous-development.md`](autonomous-development.md) | Pre-flight → Plan → per-task/wave JIT Analyze, Disjoint Wave / Implement, Scoped Verify, Snapshot, Mechanical Pass, Tiered Review/Fix, Sequential Commit → Final verification |

Progressive-disclosure references for `/autodev` (opened only on template creation or `resume`):
- [`references/autodev-templates.md`](references/autodev-templates.md) — `master-plan.md` (with `Shared contracts`), `progress.md` (with `impl_agent`), and `approach/T00N.md` schemas
- [`references/autodev-resume.md`](references/autodev-resume.md) — Scenario C Git-verified resume and freshness protocol
- Deterministic helper CLI (not an orchestrator): [`../scripts/README.md`](../scripts/README.md) (`autodev-guard.{ps1,sh}`)
- Visual diagrams & walkthrough: [`../docs/autodev-and-review-guide.md`](../docs/autodev-and-review-guide.md)

Single-pass review remains `commands/review.md`. Full loop: `commands/review-loop.md`. Full lifecycle: `commands/autodev.md`.
