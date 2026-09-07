# AGENTS.md

This is a **personal AI Engineering System**. Cursor is the first host. It is not a company handbook and not a dump of copied skills.

Cursor already loads `.cursor/rules/*.mdc` (hard rules always apply). This file is the map: where things live and what to open next. Load the smallest relevant slice. Do not load the whole repository.

## What Cursor loads

| Need | Location | When |
| --- | --- | --- |
| Always-on constraints | `.cursor/rules/*.mdc` → `rules/*.md` | Every session |
| Methods | `.cursor/skills/**/SKILL.md` | Agent selects from `description`, or `/skill-name` |
| User actions | `.cursor/commands/` | Explicit `/plan` `/implement` `/debug` `/review` `/verify` `/review-loop` |
| Isolated roles | `.cursor/agents/` | Independent review / fix |
| Default product sequence | `workflows/feature-implementation.md` | Multi-step feature work |
| Review-loop contract | `review-loop/spec.md` | Independent iterative review |
| Review-loop procedure | `review-loop/strategy.md` | `/review-loop` |
| Taxonomy / precedence | `docs/` | When a definition is required |
| Provenance | `research/` | When adapting external patterns |
| Eval fixtures | `evals/` | When changing skills/rules/loop |
| Personal context | `knowledge/personal/` | Background only; never overrides hard rules |
| Other hosts | `adapters/` | Codex / Claude later; do not create those trees here |

There is no `profiles/` directory. There is no repo-root `skills/`, `commands/`, or `agents/`.

## Architecture

Conceptual loop, not a pipeline. Definitions: `docs/architecture.md`. Conflicts: `docs/precedence.md`.

```text
Knowledge → Skills (constrained by Rules)
 → Commands / Workflows → Agents
 → Verification / Review Loop
 → Lessons Learned → Knowledge
```

## Operating constraints

1. Apply `rules/` with the precedence stack; preferences do not silently win.
2. Load the smallest relevant skill. Do not load every skill.
3. Distinguish official spec, established practice, community/research, personal experience, preference.
4. Do not copy external repositories verbatim. Record intake in `research/` (`docs/research-methodology.md`).
5. Failed tool, missing evidence, empty diff, or iteration limit → `UNKNOWN / INCOMPLETE`, not `PASS`.
6. Do not claim unimplemented layers already exist.
7. Lessons learned do not automatically become rules (`docs/system-lifecycle.md`).

## Source vs host vs docs

- **Source (meaning):** `rules/`, `.cursor/skills/`, `.cursor/commands/`, `.cursor/agents/`, `review-loop/`, `workflows/`, `evals/`, `knowledge/`
- **Cursor activation:** `.cursor/rules/*.mdc`, native skill/command/agent discovery
- **Documentation:** `docs/`, `README.md`
- **Research:** `research/` (provenance, not production config)
- **Generated (future hosts only):** `.agents/skills`, `.claude/skills` via `adapters/sync-skills.sh`

Layout decision: `research/decisions/decision-009-cursor-native-layout.md`.
