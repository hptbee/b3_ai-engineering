# AGENTS.md

This is a **personal AI Engineering System** built around a **host-neutral canonical core** (`rules/`, `skills/`, `commands/`, `agents/`, `workflows/`, `review-loop/`) with thin adapters for **Cursor**, **Codex**, **Claude Code**, and **Antigravity**. It is not a company handbook and not a dump of copied skills.

This file is the universal operating map loaded by Cursor, Codex, and Antigravity, and bridged by `CLAUDE.md` (`@AGENTS.md`) for Claude Code. Load the smallest relevant slice. Do not load the whole repository.

## Canonical map

| Need | Canonical location | When |
| --- | --- | --- |
| Always-on constraints | `AGENTS.md`; `rules/*.md` (Cursor `.cursor/rules/*.mdc` → `@rules/*.md`) | Every session |
| Methods | `skills/<category>/<name>/SKILL.md` | Description-driven or explicit skill invocation |
| User actions | `commands/*.md` (and `adapters/command-skills/` for skill-based hosts) | `/plan` `/implement` `/debug` `/review` `/verify` `/review-loop` `/autodev`, or name the intent |
| Isolated roles | `agents/*.md` | Reviewer, fixer, security reviewer, architecture reviewer, performance reviewer |
| Default product sequence | `workflows/feature-implementation.md` | Multi-step feature work inside one stage |
| Autonomous lifecycle | `workflows/autonomous-development.md` | `/autodev`: plan through verify, commit, and resume |
| Review-loop contract | `review-loop/spec.md` | Independent iterative review |
| Review-loop procedure | `review-loop/strategy.md` | `/review-loop` |
| Taxonomy / precedence | `docs/` | When a definition is required |
| Provenance | `research/` | When adapting external patterns |
| Eval fixtures | `evals/` | When changing skills, rules, workflows, or the review loop |
| Personal context | `knowledge/personal/` | Background only; never overrides hard rules |
| Host adapters | `adapters/` | Read the relevant host README; do not duplicate meaning |

There is no `profiles/` directory.

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
5. Failed tool, missing evidence, empty **named review target**, or iteration limit → `UNKNOWN / INCOMPLETE`, not `PASS`. For a code-change review that named a product diff, an empty diff is an empty target. For an explicit design-only review, the named target is the implementation approach; a missing approach is INCOMPLETE, an absent product diff is not.
6. Do not claim unimplemented layers already exist.
7. Lessons learned do not automatically become rules (`docs/system-lifecycle.md`).
8. Local host activation directories (`.cursor/{skills,commands,agents}`, `.agents/skills`, `.claude/{skills,agents}`, `.codex/skills`) are gitignored links managed by `adapters/sync-skills.{ps1,sh}` — never a second editable corpus. Do not enable conflicting skill discovery roots in the same checkout (Cursor cross-loads `.agents/skills` and `.claude/skills`; Antigravity reads both `.agents/skills.json` and `.agents/skills`).
9. In a separate product repository, resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, or this repo) and follow `workflows/autonomous-development.md` from there. Do not copy `skills/` into the product. Installer: `adapters/install-product.ps1` / `adapters/install-product.sh`.

## Source vs host vs docs

- **Canonical source (meaning):** `rules/`, `skills/`, `commands/`, `agents/`, `review-loop/`, `workflows/`, `evals/`, `knowledge/`
- **Cursor activation:** committed `.cursor/rules/*.mdc` (`@rules/*.md`) + local gitignored links `.cursor/{skills,commands,agents}` via `adapters/sync-skills.{ps1,sh} cursor`
- **Codex activation:** root `AGENTS.md` + local gitignored flattened `.agents/skills/<name>` (core `skills/` + `adapters/command-skills/`) via `adapters/sync-skills.{ps1,sh} codex`
- **Claude Code activation:** committed `CLAUDE.md` (`@AGENTS.md`) + local gitignored flattened `.claude/skills/<name>` (core `skills/` + `adapters/command-skills/`) and `.claude/agents` via `adapters/sync-skills.{ps1,sh} claude`
- **Antigravity activation:** root `AGENTS.md` + committed `.agents/skills.json` (1-level category entries over `skills/*` and `adapters/command-skills`); optional global plugin via `adapters/antigravity/install-plugin.{ps1,sh}`
- **Documentation:** `docs/`, `README.md`
- **Research:** `research/` (provenance, not production config)
