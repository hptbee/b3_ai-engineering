# AGENTS.md

Product repo attached to B3. Never copy B3 `skills/` here; load the smallest relevant slice.

## Locate `B3_HOME`

Resolve `B3_HOME` in order; stop at the first dir containing `workflows/ship.md` (else stop):
1. `B3_HOME` env var
2. `.b3/home` at product git root (1 line, absolute path)

## Locations & Invocations

| Need | Location |
| --- | --- |
| Skills | `.agents/skills/<name>/SKILL.md` (Codex/AGY), `.claude/skills/<name>/SKILL.md` (Claude), `~/.cursor/skills/<name>/SKILL.md` (Cursor global via `b3 install cursor`). Source: `{B3_HOME}/skills` (no link edits). |
| Rules / Workflows / Review / Roles | `{B3_HOME}/rules/*.md`, `{B3_HOME}/workflows/`, `{B3_HOME}/review-loop/`, `{B3_HOME}/agents/` (or `.claude/agents/`). |
| Cursor commands / Checkpoints | `.cursor/commands/` (from `{B3_HOME}/commands/`); checkpoints in `.b3/ship/` and `.b3/research-ship/` (gitignored). |

Hosts use `$<name>` (Codex), `/<name>` (Claude), or intent (AGY): `b3-ship`, `b3-research-ship`, `b3-plan`, `b3-implement`, `b3-debug`, `b3-review`, `b3-verify`, `b3-review-loop`, `b3-pr-resolve`, `b3-pr-reply`, `b3-pr-comment`.
- On `/b3-ship`, `$b3-ship`, or `b3-ship`: **read and follow** `{B3_HOME}/workflows/ship.md` directly (do not stop after Plan).
- On `/b3-review-loop` or `$b3-review-loop`: **read and follow** `{B3_HOME}/review-loop/strategy.md` directly; delegate `{B3_HOME}/agents/{b3-reviewer,b3-fixer,b3-security-reviewer,b3-architecture-reviewer,b3-performance-reviewer}.md` when isolated (parent owns `PASS`/`FAIL`/`UNKNOWN`/`INCOMPLETE`).

## Constraints

1. Apply `{B3_HOME}/rules/` per precedence; preferences never silently override rules.
2. Load only the smallest relevant skill; tool fail, missing evidence, empty target, or iter cap -> `UNKNOWN / INCOMPLETE`.
3. `.agents/skills` & `.claude/skills` are local indexes, not editable trees (in Cursor, drop duplicate discovery roots).
