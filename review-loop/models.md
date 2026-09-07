# Model / role slots

This repository does **not** hard-code vendor model names. Hosts differ (Cursor, Codex, Claude Code).

| Slot | Default | Responsibility |
| --- | --- | --- |
| **Orchestrator** | Current session / inherit | Size, units, finding log, iteration, stop |
| **Reviewer** | Isolated subagent if the host allows; else a hat-change in-session | Review only; no edits |
| **Fixer** | Isolated subagent if the host allows; else a hat-change | Validate + minimal fix + invoke verification; no PASS |

Prefer **different** models for Reviewer vs Fixer when the host supports it (independent judgment). Configure in the host (Cursor subagent `model` field, Claude agent model, Codex profile) — not in portable skills.

Adapter notes: [`../adapters/cursor/README.md`](../adapters/cursor/README.md), [`../adapters/claude/README.md`](../adapters/claude/README.md).

Until a host mapping exists, run all three slots in one session with a strict role split.
