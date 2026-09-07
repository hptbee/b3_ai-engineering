# AGENTS.md

This is a **personal AI Engineering System**: a portable operating layer for AI coding agents. It is not a company repository, not a project-specific rule set, and not a dump of copied skills.

Use this file as the entry point. Load `docs/`, `rules/`, `skills/`, and `knowledge/` only when the current task needs them. Do not assume a `profiles/` directory exists.

## Architecture

Conceptual feedback loop, not a strict pipeline. Full taxonomy: `docs/architecture.md`.

```text
Knowledge → Skills (constrained by Rules)
    → Commands / Workflows → Agents
    → Verification / Review Loop
    → Lessons Learned → Knowledge
```

- **Rules** constrain behavior. What must always be true?
- **Skills** provide specialized methods. How should this task be done?
- **Commands** initiate explicit actions. What should be done now? Thin files in `commands/`.
- **Workflows** orchestrate steps. In what order? See `workflows/`.
- **Agents** are specialized roles. Who should handle this? Independent reviewers in `agents/`.
- **Verification** requires evidence. A missing check is `UNKNOWN / INCOMPLETE`, not `PASS`.
- **Review Loop** is independent iterative validation. Spec: `docs/review-loop.md`. One-shot orchestration: `commands/review-loop.md`.
- **Knowledge** feeds the system and receives lessons. It is not a rule.
- **Profiles** are personal context, not universal truth, and never override safety, correctness, project requirements, hard rules, or platform constraints. The `profiles/` directory is not created; background context is `knowledge/personal/`.
- **Research** (`research/`) is where conclusions came from.
- **Adapters** map the portable core onto Cursor, Codex, or Claude Code. They must not fork meaning.

Until a host runner exists, default to `workflows/feature-implementation.md`.

Conflicts: `docs/precedence.md` (safety and platform → user request → project requirements → hard rules → … → preferences).

## Operating constraints

1. Apply `rules/` with the precedence stack; preferences do not silently win.
2. Load the smallest relevant skill. Do not load the whole repository.
3. Distinguish official spec, established practice, community/research, personal experience, preference.
4. Do not copy external repositories verbatim. Record intake in `research/` when that phase runs.
5. Failed tool, missing evidence, empty diff, or iteration limit → `UNKNOWN / INCOMPLETE`, not `PASS`.
6. Do not claim unimplemented layers already exist.
7. Lessons learned do not automatically become rules (`docs/system-lifecycle.md`).

## Where to look

| Need | Location |
| --- | --- |
| Taxonomy | `docs/architecture.md` |
| Precedence | `docs/precedence.md` |
| Lifecycle | `docs/system-lifecycle.md` |
| Skill standard | `docs/skill-standard.md` |
| Rule standard | `docs/rule-standard.md` |
| Review loop | `docs/review-loop.md` + `review-loop/strategy.md` |
| Knowledge vs references | `docs/knowledge-system.md` |
| Evaluation | `docs/evaluation.md` |
| Research method | `docs/research-methodology.md` |
| Skills catalog | `skills/README.md` |
| Commands | `commands/` |
| Agents | `agents/` |
| Workflows | `workflows/` |
| Evals | `evals/` |
| Adapters | `adapters/` |
| Personal context | `knowledge/personal/` (`profiles/` not created) |
