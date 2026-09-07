# Agents

Agents are specialized roles. They answer: **who should handle this?**

**Status:** present (two independent reviewers). Not a running multi-agent runtime. Host subagent files belong in `adapters/`.

| Agent | Mandate | Why not a skill only |
| --- | --- | --- |
| [`security-reviewer.md`](security-reviewer.md) | Authn/z, trust boundaries | Isolation from implementer (decision-004) |
| [`architecture-reviewer.md`](architecture-reviewer.md) | Boundaries, unjustified complexity | Isolation from the author of the design |

Skills stay shared (`api-security`, `simplest-correct`, `code-review`).

Backlog (not created): frontend/performance/test/UX reviewers — use `code-review` dimensions until isolation is needed in real use.

Do not treat this folder as a swarm.
