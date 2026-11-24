# Workflows

Workflows are multi-step orchestration. They answer: **in what order should things happen?**

**Status:** present (default product sequence, plus full `/b3-ship` lifecycle). Independent review is not a third workflow file — it is `review-loop/` invoked by `commands/b3-review-loop.md` and `/b3-ship`.

| Workflow | Sequence |
| --- | --- |
| [`feature-implementation.md`](feature-implementation.md) | `Scope → Plan → Build → Verify → Review → Fix → Verify` |
| [`ship.md`](ship.md) | `Preflight → Plan → [Scope → Build → Verify → Review → Commit] → Finalize` |
| [`research-ship.md`](research-ship.md) | `Preflight → Research Plan → Source Discovery → Analysis → Independent Verify → Formalization → [Impl → Review/Editorial] → PR → Merge Eligibility → Post-Merge` |

Progressive-disclosure references for `/b3-ship` (opened only on template creation or `resume`):
- [`references/ship-templates.md`](references/ship-templates.md) — `master-plan.md` (`Shared contracts`), `progress.md` (`impl_agent`), risk-adaptive `detailed` matrices (`failure_matrix`, `write_paths`, `io_budget`), Context Packets, and `approach/T00N.md` schemas
- [`references/ship-resume.md`](references/ship-resume.md) — Scenario C Git-verified resume, freshness/`verify-check` validation, and read-only `.b3/autodev/` legacy fallback
- [`references/research-ship-templates.md`](references/research-ship-templates.md) — `.b3/research-ship/` run `progress.md`, `research-plan.md`, `evidence-index.md`, and `.b3/research-policy.json` schema
- [`references/research-ship-resume.md`](references/research-ship-resume.md) — `.b3/research-ship/` Git, PR, and `evidence-check` freshness resume + read-only `status`
- [`references/research-ship-gates.md`](references/research-ship-gates.md) — independent source verification, dual technical/editorial gates, PR lifecycle, and `merge-policy-check` / post-merge checks
- [`references/dispatch-naming.md`](references/dispatch-naming.md) — on-demand subagent logical alias & host-safe fallback contract (loaded only at dispatch)
- [`references/context-routing.md`](references/context-routing.md) — on-demand capability-aware context routing contract for optional Codebase Memory / Serena MCPs with native fallback
- [`references/pr-template.md`](references/pr-template.md) — shared PR description template (`Summary`, `Changes`, `Verification`, `Risks & Compatibility`, `Checklist`) for `gh pr create` / `gh pr edit`
- Deterministic helper CLI (not an orchestrator): [`../scripts/README.md`](../scripts/README.md) (`b3-guard.{ps1,sh}`)
- Visual diagrams & walkthrough: [`../docs/ship-and-review-guide.md`](../docs/ship-and-review-guide.md)

Single-pass review remains `commands/b3-review.md`. Full loop: `commands/b3-review-loop.md`. Full lifecycle: `commands/b3-ship.md`.
