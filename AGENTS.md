# AGENTS.md

This is a **personal AI Engineering System**. Cursor is the first host and Codex is now supported. It is not a company handbook and not a dump of copied skills.

Cursor loads `.cursor/rules/*.mdc`; Codex loads this file and discovers skills through the local `.agents/skills` installation. This file is the map: where things live and what to open next. Load the smallest relevant slice. Do not load the whole repository.

## What Cursor loads

| Need | Location | When |
| --- | --- | --- |
| Always-on constraints | `AGENTS.md`; Cursor `.cursor/rules/*.mdc` → `rules/*.md` | Every session |
| Methods | Cursor `.cursor/skills/**/SKILL.md`; Codex `.agents/skills/**/SKILL.md` → Cursor source | Description-driven or explicit skill invocation |
| User actions | Cursor `.cursor/commands/`; Codex prompt routing | `/plan` `/implement` `/debug` `/review` `/verify` `/review-loop` `/autodev`, or name the intent |
| Isolated roles | Cursor `.cursor/agents/`; Codex delegated role prompts | Reviewer, fixer, security reviewer, architecture reviewer |
| Default product sequence | `workflows/feature-implementation.md` | Multi-step feature work inside one stage |
| Autonomous lifecycle | `workflows/autonomous-development.md` | `/autodev`: plan through verify, commit, and resume |
| Review-loop contract | `review-loop/spec.md` | Independent iterative review |
| Review-loop procedure | `review-loop/strategy.md` | `/review-loop` |
| Taxonomy / precedence | `docs/` | When a definition is required |
| Provenance | `research/` | When adapting external patterns |
| Eval fixtures | `evals/` | When changing skills, rules, workflows, or the review loop |
| Personal context | `knowledge/personal/` | Background only; never overrides hard rules |
| Host adapters | `adapters/` | Read the relevant host README; do not duplicate meaning |

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
5. Failed tool, missing evidence, empty **named review target**, or iteration limit → `UNKNOWN / INCOMPLETE`, not `PASS`. For a code-change review that named a product diff, an empty diff is an empty target. For design-only architecture review, the named target is the implementation approach; a missing approach is INCOMPLETE, an absent product diff is not.
6. Do not claim unimplemented layers already exist.
7. Lessons learned do not automatically become rules (`docs/system-lifecycle.md`).
8. `.agents/skills` is a local installation link to `.cursor/skills`, not a second editable skill corpus. Set it up with `adapters/sync-skills.ps1` on Windows or `adapters/sync-skills.sh` on macOS/Linux.
9. In a separate product repository, resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, or this repo) and follow `workflows/autonomous-development.md` from there. Do not copy `.cursor/skills` into the product. Installer: `adapters/install-product.ps1` / `adapters/install-product.sh`.

## Source vs host vs docs

- **Source (meaning):** `rules/`, `.cursor/skills/`, `.cursor/commands/`, `.cursor/agents/`, `review-loop/`, `workflows/`, `evals/`, `knowledge/`
- **Cursor activation:** `.cursor/rules/*.mdc`, native skill/command/agent discovery
- **Codex activation:** root `AGENTS.md`, plus the local `.agents/skills` link to `.cursor/skills`; use prompt routing for commands and delegated roles
- **Documentation:** `docs/`, `README.md`
- **Research:** `research/` (provenance, not production config)
- **Local installation artifacts:** `.agents/skills` and `.claude/skills` are ignored links created by adapter helpers; they are never independently edited or committed.

Layout decision: `research/decisions/decision-009-cursor-native-layout.md`.
