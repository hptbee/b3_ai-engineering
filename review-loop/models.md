# Model / role slots & Cost-Preserving Quality Tiering

Portable contract. This file does **not** name vendor models. Hosts differ (Cursor, Codex, Claude Code, Antigravity). Optional personal/project Markdown preferences live in `~/.b3/models.md` and `<project>/.b3/models.md` (template: [`../config/models.example.md`](../config/models.example.md); guide: [`../docs/model-preferences.md`](../docs/model-preferences.md)). Where unsupported, hosts inherit their native model.

## Three slots (`/b3-review-loop`)

| Slot | Default | Responsibility | Must not |
| --- | --- | --- | --- |
| **Orchestrator** | Current session | Size, dispatch, finding log, iteration, **stop** | Review and fix in the same pass |
| **Reviewer** | Isolated subagent if host allows; else hat-change | One review pass; findings only | Edit code; declare loop PASS / INCOMPLETE / STOP |
| **Fixer** | Isolated subagent if host allows; else hat-change | Validate findings; minimal edit; run verification | Declare loop PASS / INCOMPLETE / STOP; re-review the whole PR |

Only the **orchestrator** declares `PASS`, `INCOMPLETE`, `STUCK`, or STOP. Reviewer and Fixer return work products (findings, diffs, verification evidence).

## Cost-Preserving Quality Tiering (`/b3-ship` & `/b3-review-loop`)

When the host supports per-agent or per-subagent model selection, split reasoning vs execution across 4 portable tiers based on **risk & complexity** (never size alone; optimize total verified-PR cost, never per-call price alone, and never omit mandatory `CRITICAL`/contract coverage to meet a cost target):

| Tier | Roles / Tasks | Why this tier | Guardrails |
| --- | --- | --- | --- |
| **Deep / high-reasoning** | `Orchestrator` (`Plan`, `Scope`), hard debugging, `b3-reviewer`, `b3-architecture-reviewer`, `b3-security-reviewer`, `b3-performance-reviewer` | Architecture, invariants, contract design, and independent defect detection require full reasoning depth | Never dilute `Plan`, `Scope`, or `Reviewer` onto a weaker tier |
| **Standard execution** | Complex multi-file implementation, shared-contract integration, substantial refactoring | Stronger state/invariant tracking avoids multi-round verify retries on non-trivial builds | Pair with concrete `approach/T00N.md`, `verify-run`, and **Deep** independent review |
| **Fast execution** | Bounded `inline`/`notes` coding, small surgical `Fixer` edits, routine tests, docs | Fast edits when `files`, `line`, `bug_class`, and contracts are already pinned | Protected by `verify-run`, `mechanical-check`/`symbol-check`, and **Deep** `Reviewer` |
| **Deterministic (0-token)** | `b3 guard` (`diff-scope`, `mechanical-check`, `symbol-check`, `verify-run`/`check`, `check-wave`, `check-worktree`, `precommit`), Git, lint, builds | Deterministic scripts establish structural facts faster and with zero hallucination | Never replace deterministic CLI verification with LLM self-report |

**Cost-Aware Escalation:** start bounded coding/fixes on **Fast**, multi-file/complex implementation on **Standard** (when host supports a middle tier), and **escalate one tier up** on repeated `verify-run` failures or when the **2-Tier Circuit Breaker** (`review-loop/strategy.md` §1.3) fires.

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
