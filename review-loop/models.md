# Model / role slots & Cost-Preserving Quality Tiering

Portable contract. This file does **not** name vendor models. Hosts differ (Cursor, Codex, Claude Code, Antigravity). Where to set `model:` is host config, not this spec.

## Three slots (`/b3-review-loop`)

| Slot | Default | Responsibility | Must not |
| --- | --- | --- | --- |
| **Orchestrator** | Current session | Size, dispatch, finding log, iteration, **stop** | Review and fix in the same pass |
| **Reviewer** | Isolated subagent if host allows; else hat-change | One review pass; findings only | Edit code; declare loop PASS / INCOMPLETE / STOP |
| **Fixer** | Isolated subagent if host allows; else hat-change | Validate findings; minimal edit; run verification | Declare loop PASS / INCOMPLETE / STOP; re-review the whole PR |

Only the **orchestrator** declares `PASS`, `INCOMPLETE`, `STUCK`, or STOP. Reviewer and Fixer return work products (findings, diffs, verification evidence).

## Cost-Preserving Quality Tiering (`/b3-ship` & `/b3-review-loop`)

When the host supports per-agent or per-subagent model selection, split reasoning vs execution without lowering quality:

| Tier | Roles | Why this tier | Guardrails |
| --- | --- | --- | --- |
| **Deep / high-reasoning** | `Orchestrator` (`Plan`, `Scope`), `b3-reviewer`, `b3-architecture-reviewer`, `b3-security-reviewer`, `b3-performance-reviewer` | Architecture, invariants, contract design, and independent defect detection require full reasoning depth | Never dilute `Plan`, `Scope`, or `Reviewer` onto a weaker tier |
| **Fast / surgical coding** | `Build` worker (`impl_agent`), `Fixer` | Bounded edits with concrete `approach/T00N.md` (after `Gate`) or `file:line` + `bug_class` | Protected by `0`-token CLI `mechanical-check`, executed `Verify` tests, and independent **Deep** `Reviewer` |

Do not put vendor model IDs in `spec.md`, `strategy.md`, skills, or this file. Configure them in host agent files (e.g., Cursor `agents/*.md` `model:` field — see [`../adapters/cursor/review-loop-models.md`](../adapters/cursor/review-loop-models.md)).

## Default: one session

Committed agent frontmatter uses `model: inherit` on Reviewer and Fixer: same model as parent session, **strict hat-change** if the host cannot isolate subagents.

```text
Reviewer pass: no edits
Fixer pass: no loop outcome
Orchestrator: merge log, gate, stop
```

## Dispatch

Each **review** pass → Reviewer. Each **fix** pass → Fixer. After fixes, a **fresh** Reviewer pass on current code — not “did we fix R001?”

If subagents cannot be launched: keep the three hats in one session. Do not collapse review+fix into one mixed pass.

Adapter index: [`../adapters/cursor/README.md`](../adapters/cursor/README.md), [`../adapters/claude/README.md`](../adapters/claude/README.md).
