# Agents

Agents are specialized roles. They answer: **who should handle this?**

Canonical role definitions live here (`agents/`). Cursor maps them via `.cursor/agents` (`sync-skills cursor`), Claude Code via `.claude/agents` (`sync-skills claude`), Antigravity via plugin generation (`adapters/antigravity/install-plugin.*`), and Codex via delegated role prompts. Orchestration is `review-loop/strategy.md`. Skills stay shared; agents exist for **isolation**.

| Agent | Mandate | Why not a skill only |
| --- | --- | --- |
| [`reviewer.md`](reviewer.md) | One independent review pass; no edits | Isolation from the fixer |
| [`fixer.md`](fixer.md) | Validate then minimal fix + verification; no PASS | Isolation from the reviewer |
| [`security-reviewer.md`](security-reviewer.md) | Authn/z, trust boundaries | Isolation from implementer (decision-004) |
| [`architecture-reviewer.md`](architecture-reviewer.md) | Boundaries, unjustified complexity | Isolation from the author of the design |
| [`performance-reviewer.md`](performance-reviewer.md) | Material perf risks/regressions; evidence before optimize | Isolation on **hot-path** diffs only |

Skills stay shared (`api-security`, `simplest-correct`, `code-review`, `verification`, domain performance skills). Model slots: `review-loop/models.md`. Committed default is `model: inherit` on these files. Two-model Cursor setup: `adapters/cursor/review-loop-models.md`.

Backlog (not created): frontend/test/UX reviewers — use `code-review` dimensions until isolation is needed in real use.

Do not treat this folder as a swarm. Independent review actually working in hosts (auto-delegation) is **NOT VERIFIED** in this change; files live in canonical `agents/` and are mapped onto host discovery paths via `adapters/`.
