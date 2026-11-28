# Workflows

Workflows are multi-step orchestration. They answer: **in what order should things happen?**

**Status:** present (default product sequence, plus full `/b3-ship` and `/b3-research-ship` lifecycles). Independent review is not a separate workflow file — it is `review-loop/` invoked by `commands/b3-review-loop.md` and `/b3-ship`.

| Workflow | Sequence |
| --- | --- |
| [`feature-implementation.md`](feature-implementation.md) | `Scope → Plan → Build → Verify → Review → Fix → Verify` |
| [`ship.md`](ship.md) | `Preflight → Plan → [Scope → Build → Verify → Review → Commit] → Finalize` |
| [`research-ship.md`](research-ship.md) | `Preflight → Research Plan → Source Discovery → Analysis → Independent Verify → Formalization → [Impl → Review/Editorial] → Branch/PR → Merge Eligibility → Post-Merge` |

Progressive-disclosure references for `/b3-ship` and `/b3-research-ship` (opened only on demand):
- [`references/ship-templates.md`](references/ship-templates.md) — `master-plan.md` (`Shared contracts`), `progress.md` (`impl_agent`), risk-adaptive `detailed` matrices (`failure_matrix`, `write_paths`, `io_budget`), Context Packets (omitting `## Inspected`), and `approach/T00N.md` schemas
- [`references/ship-resume.md`](references/ship-resume.md) — Scenario C Git-verified resume, `check-freshness`/`verify-check` validation, and legacy `.b3/ship/progress.md` support
- [`references/research-ship-templates.md`](references/research-ship-templates.md) — `.b3/research-ship/` `progress.md`, `research-plan.md`, `evidence-index.md`, and `.b3/research-policy.json` schema
- [`references/research-ship-resume.md`](references/research-ship-resume.md) — `.b3/research-ship/` Git, branch/PR, and `evidence-check` freshness resume + read-only `status`
- [`references/research-ship-gates.md`](references/research-ship-gates.md) — independent source verification, dual technical/editorial gates, provider-neutral branch/PR lifecycle, and `merge-policy-check` / post-merge checks
- [`references/dispatch-naming.md`](references/dispatch-naming.md) — subagent logical aliases, optional model preferences, adaptive concurrency & continuous dispatch, 4 isolation modes, and canonical `mechanical-check` ownership contract
- [`references/context-routing.md`](references/context-routing.md) — capability-aware context routing contract for optional Codebase Memory / Serena MCPs with native fallback
- [`references/static-analysis.md`](references/static-analysis.md) — project-native lint/SAST/dead-code discovery (`REUSE`/`FALLBACK`/authorized `BOOTSTRAP`), scoped safe auto-fix, baseline regression attribution, and mechanical review offloading
- [`references/pr-template.md`](references/pr-template.md) — provider-neutral branch/PR description template (`{RUN_DIR}/pr-body.md`, optional `gh pr` on GitHub)
- Deterministic native CLI (not an orchestrator): `b3 guard` / `b3 pr` / `b3 context measure` (`src/`)
- Visual diagrams & walkthrough: [`../docs/ship-and-review-guide.md`](../docs/ship-and-review-guide.md)

Single-pass review remains `commands/b3-review.md`. Full loop: `commands/b3-review-loop.md`. Full lifecycles: `commands/b3-ship.md` and `commands/b3-research-ship.md`.
