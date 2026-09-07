# Agents

Agents are specialized roles. They answer: **who should handle this?**

**Status:** present (reviewer / fixer plus two specialist reviewers). Not a host plugin. Orchestration is `review-loop/strategy.md`. Host subagent files belong in `adapters/`.

| Agent | Mandate | Why not a skill only |
| --- | --- | --- |
| [`reviewer.md`](reviewer.md) | One independent review pass; no edits | Isolation from the fixer |
| [`fixer.md`](fixer.md) | Validate then minimal fix + verification; no PASS | Isolation from the reviewer |
| [`security-reviewer.md`](security-reviewer.md) | Authn/z, trust boundaries | Isolation from implementer (decision-004) |
| [`architecture-reviewer.md`](architecture-reviewer.md) | Boundaries, unjustified complexity | Isolation from the author of the design |

Skills stay shared (`api-security`, `simplest-correct`, `code-review`, `verification`). Model slots: `review-loop/models.md`.

Backlog (not created): frontend/performance/test/UX reviewers — use `code-review` dimensions until isolation is needed in real use.

Do not treat this folder as a swarm.
