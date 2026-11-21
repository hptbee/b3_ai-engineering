# AGENTS.md

This product repository is attached to B3. Do not copy B3 skills into this repo. Load the smallest relevant slice.

## Locate B3

Resolve `B3_HOME` in this order. Stop at the first match that contains `workflows/autonomous-development.md`:

1. Environment variable `B3_HOME`
2. Product git root file `.b3/home` (one line, absolute path)

If none match → stop. Do not invent a second procedure.

## What to load

| Need | Location |
| --- | --- |
| Skills | Host local link (`.agents/skills/<name>/SKILL.md` for Codex/Antigravity, `.claude/skills/<name>/SKILL.md` for Claude Code, or user-level `~/.cursor/skills/b3-ai-engineering` for Cursor). Canonical source is `{B3_HOME}/skills`; do not edit through the link. |
| Commands (Cursor slash) | This repo `.cursor/commands/` (sourced from `{B3_HOME}/commands/`) |
| Rules | `{B3_HOME}/rules/*.md` |
| Workflows | `{B3_HOME}/workflows/` |
| Review loop | `{B3_HOME}/review-loop/` |
| Isolated roles | `{B3_HOME}/agents/` (or `.claude/agents/` in Claude Code) |

Product files and Git commits stay in this repository. Checkpoints go under `.b3/autodev/` (gitignored).

## Codex, Claude Code, and Antigravity invocation

Skill-based hosts (**Codex**, **Claude Code**, **Antigravity**) invoke B3 commands through skills (Codex `$<name>` / `/skills`; Claude Code `/<name>` via `.claude/skills/<name>`; Antigravity skill activation or prompt intent):

| Intent | Invoke |
| --- | --- |
| Autonomous lifecycle | `autodev` (`$autodev` / `/autodev`) |
| Plan only | `plan` (`$plan` / `/plan`) |
| Implement | `implement` (`$implement` / `/implement`) |
| Debug | `debug` (`$debug` / `/debug`) |
| Review | `review` (`$review` / `/review`) |
| Verify | `verify` (`$verify` / `/verify`) |
| Review loop | `review-loop` (`$review-loop` / `/review-loop`) |

When the user says “autodev”, “run autodev”, `$autodev`, or `/autodev`, **read and follow** `{B3_HOME}/commands/autodev.md` (or the `autodev` skill), then `{B3_HOME}/workflows/autonomous-development.md`. Do not stop after the plan.

For review-loop delegation, send `{B3_HOME}/agents/reviewer.md`, `fixer.md`, `security-reviewer.md`, `architecture-reviewer.md`, or `performance-reviewer.md` to an isolated agent when available. The parent owns `PASS`, `FAIL`, and `UNKNOWN / INCOMPLETE`.

## Operating constraints

1. Apply `{B3_HOME}/rules/` with the precedence stack; preferences do not silently win.
2. Load the smallest relevant skill. Do not load every skill.
3. Failed tool, missing evidence, empty named review target, or iteration limit → `UNKNOWN / INCOMPLETE`, not `PASS`.
4. Do not copy `{B3_HOME}/skills` into this product.
5. `.agents/skills` and `.claude/skills` are local installation indexes (one folder per skill), not second editable skill trees.

Cursor also discovers `.agents/skills` and `.claude/skills`. If this checkout is opened in Cursor, skills may appear twice unless other discovery roots for the same tree are removed.
