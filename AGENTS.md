# AGENTS.md

This is a **personal AI Engineering System**: a portable operating layer for AI coding agents. It is not a company repository, not a project-specific rule set, and not a dump of copied skills.

Use this file as the entry point. Load details from `docs/`, `rules/`, and `skills/` only when the current task needs them.

## Architecture

```text
Rules
  ↓
Skills
  ↓
Commands / Workflows
  ↓
Agents
  ↓
Verification
  ↓
Review Loop
  ↓
Knowledge / Learning
```

Adapters sit beside this stack. They map the portable core onto Cursor, Codex, or Claude Code. They must not become a second source of truth.

### Rules — what must always be true?

Persistent constraints. Short, explicit, durable. Apply them on every task unless a rule itself scopes an exception.

Current foundation: `rules/`.

### Skills — how should this task be done?

Reusable engineering knowledge and workflows. Skills are focused, composable, and loaded on demand.

Current foundation: `skills/engineering/`. Future domains live under `skills/` as they are researched and written.

### Commands — what action should the agent perform now?

Explicit user-triggered operations. The command layer is specified, not implemented. See `commands/README.md`.

### Agents — who should handle this?

Specialized roles (architect, security reviewer, researcher, and similar). Roles are specified, not implemented. See `agents/README.md`.

### Workflows — in what order should things happen?

Multi-step orchestration across skills, commands, and agents. Workflows are specified, not implemented. See `workflows/README.md`.

Until dedicated workflow files exist, default to:

```text
Understand → Plan → Implement → Verify → Review → Fix → Re-verify
```

### Review Loop — is the implementation actually correct?

Independent verification and iterative correction. The loop is specified in `docs/review-loop.md`. Runtime artifacts will live under `review-loop/` as the loop is implemented.

Never treat “looks good”, “tests probably pass”, or “the model says it works” as verification.

### Knowledge — what have we learned?

Reusable engineering knowledge and lessons, split into stable, volatile, and personal. See `docs/knowledge-system.md` and `knowledge/`.

Personal experience is context, not universal truth.

### Adapters — how does this work in Cursor / Codex / Claude?

Thin, platform-specific integration. See `adapters/`.

## Operating constraints

1. Follow `rules/` before applying a skill.
2. Prefer the smallest relevant skill. Do not load the whole repository.
3. Distinguish evidence classes: official spec, established practice, community/research, personal experience, personal preference.
4. Do not copy external repositories verbatim. Research, adapt, personalize, verify, then record provenance.
5. A failed tool, missing evidence, or incomplete check is `UNKNOWN / INCOMPLETE`, not `PASS`.
6. Do not claim that unimplemented layers (commands, agents, workflows, evals, review-loop runtime) already exist.

## Where to look

| Need | Location |
| --- | --- |
| Taxonomy | `docs/architecture.md` |
| Skill standard | `docs/skill-standard.md` |
| Rule standard | `docs/rule-standard.md` |
| Review loop | `docs/review-loop.md` |
| Knowledge | `docs/knowledge-system.md` |
| Evaluation | `docs/evaluation.md` |
| Research method | `docs/research-methodology.md` |
