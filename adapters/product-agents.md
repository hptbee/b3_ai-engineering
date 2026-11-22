# AGENTS.md

Product repo attached to B3. Never copy B3 `skills/` here; load the smallest relevant slice.

## Locate `B3_HOME`

Resolve `B3_HOME` in order; stop at the first dir containing `workflows/autonomous-development.md` (else stop):
1. `B3_HOME` env var
2. `.b3/home` at product git root (1 line, absolute path)

## Locations & Invocations

| Need | Location |
| --- | --- |
| Skills | `.agents/skills/<name>/SKILL.md` (Codex/AGY), `.claude/skills/<name>/SKILL.md` (Claude), `~/.cursor/skills/b3-ai-engineering` (Cursor). Source: `{B3_HOME}/skills` (no link edits). |
| Rules / Workflows / Review / Roles | `{B3_HOME}/rules/*.md`, `{B3_HOME}/workflows/`, `{B3_HOME}/review-loop/`, `{B3_HOME}/agents/` (or `.claude/agents/`). |
| Cursor commands / Checkpoints | `.cursor/commands/` (from `{B3_HOME}/commands/`); checkpoints in `.b3/autodev/` (gitignored). |

Hosts use `$<name>` (Codex), `/<name>` (Claude), or intent (AGY): `autodev`, `plan`, `implement`, `debug`, `review`, `verify`, `review-loop`.
- On `/autodev`, `$autodev`, or `autodev`: **read and follow** `{B3_HOME}/workflows/autonomous-development.md` directly (do not stop after plan).
- On `/review-loop` or `$review-loop`: **read and follow** `{B3_HOME}/review-loop/strategy.md` directly; delegate `{B3_HOME}/agents/{reviewer,fixer,security-reviewer,architecture-reviewer,performance-reviewer}.md` when isolated (parent owns `PASS`/`FAIL`/`UNKNOWN`/`INCOMPLETE`).

## Constraints

1. Apply `{B3_HOME}/rules/` per precedence; preferences never silently override rules.
2. Load only the smallest relevant skill; tool fail, missing evidence, empty target, or iter cap -> `UNKNOWN / INCOMPLETE`.
3. `.agents/skills` & `.claude/skills` are local indexes, not editable trees (in Cursor, drop duplicate discovery roots).
