---
type: rule
strength: hard
scope: global
source: synthesized
authority: high
---

# Agent and Sub-agent Naming

Hard rule: every B3 agent and spawned sub-agent must use a deterministic lowercase `kebab-case` name with the `b3-` prefix (`[a-z0-9-]`, max 24 chars where host rosters enforce limits). Never invent ad-hoc names, freeform titles (`"Autodev Worker"`, `"Worker T002"`, `"Code Reviewer"`, `"Fixer Agent"`), random suffixes, timestamps, or camelCase between runs.

Hard rule: never use `autodev` or `worker` (`workers`) in spawned agent/sub-agent names, role labels, briefs, plans, progress tables, or dispatch calls. Reserve `worker` strictly for application runtime primitives (e.g., `worker_threads`, background job services); `autodev` is retired (only read-only `.b3/autodev/` legacy checkpoint fallback in `b3-guard` remains).

## Spawn-time contract

When spawning any sub-agent (via `invoke_subagent`, Cursor/Claude/Codex subagent dispatch, or `swarm`), pass the exact deterministic `b3-*` name:

- **Canonical agent files (`agents/*.md`) & role invocation:** filename stem, YAML `name:`, and spawned name must match exactly:
  - Core roles: `b3-<role>` (`b3-reviewer`, `b3-fixer`)
  - Specialist reviewers: `b3-<domain>-reviewer` (`b3-security-reviewer`, `b3-architecture-reviewer`, `b3-performance-reviewer`)
- **Build / implementation sub-agent:** `b3-impl-<task-id>` in lowercase (e.g., `b3-impl-t001`, `b3-impl-t002`), or `b3-impl-<slug>` when no task ID exists.
- **Read-only research sub-agent:** `b3-research-<slug>` (e.g., `b3-research-auth`).
- **Host display `Role` parameter (e.g., Antigravity `invoke_subagent`):** pass the exact same `b3-*` name (`b3-impl-t002`, `b3-reviewer`, `b3-fixer`, `b3-research-auth`) so every run displays and logs the identical name.
