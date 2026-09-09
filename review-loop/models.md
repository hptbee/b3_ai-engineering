# Model / role slots

Portable contract. This file does **not** name vendor models. Hosts differ (Cursor, Codex, Claude Code). Where to set `model:` is host config, not this spec.

## Three slots

| Slot | Default | Responsibility | Must not |
| --- | --- | --- | --- |
| **Orchestrator** | Current session | Size, dispatch, finding log, iteration, **stop** | Review and fix in the same pass |
| **Reviewer** | Isolated subagent if the host allows; else hat-change | One review pass; findings only | Edit code; declare loop PASS / INCOMPLETE / STOP |
| **Fixer** | Isolated subagent if the host allows; else hat-change | Validate findings; minimal edit; run verification | Declare loop PASS / INCOMPLETE / STOP; re-review the whole PR |

Only the **orchestrator** declares `PASS`, `INCOMPLETE`, `STUCK`, or STOP. Reviewer and Fixer return work products (findings, diffs, verification evidence).

## Default: one session

Committed agent frontmatter uses `model: inherit` on Reviewer and Fixer. That means: same model as the parent session, **strict hat-change** if the host cannot isolate subagents.

```text
Reviewer pass: no edits
Fixer pass: no loop outcome
Orchestrator: merge log, gate, stop
```

## Two-model (optional)

When the host supports per-agent models, set a **deeper** model on Reviewer and a **faster/surgical** model on Fixer in **that host’s agent files** (Cursor: `.cursor/agents/*.md` `model:` field). Do not put those ids in `spec.md`, skills, or this file.

How to set them in Cursor: [`../adapters/cursor/review-loop-models.md`](../adapters/cursor/review-loop-models.md). Claude/Codex: adapter READMEs when those hosts are used.

## Dispatch

Each **review** pass → Reviewer. Each **fix** pass → Fixer. After fixes, a **fresh** Reviewer pass on current code — not “did we fix R001?”

If subagents cannot be launched: keep the three hats in one session. Do not collapse review+fix into one mixed pass.

Adapter index: [`../adapters/cursor/README.md`](../adapters/cursor/README.md), [`../adapters/claude/README.md`](../adapters/claude/README.md).
