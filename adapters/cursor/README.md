# Cursor adapter

Cursor consumes this repository **directly**. `.cursor/skills`, `.cursor/commands`, `.cursor/agents`, and `.cursor/rules` are committed source, not a generated copy.

Discovery of skills after placing them on the native path is **VERIFIED** by Cursor docs ([cursor.com/docs/skills](https://cursor.com/docs/skills)). Auto-activation in a new Agent session is **NOT VERIFIED** in this change. Slash commands and subagent auto-delegation are **INTENDED**.

## What Cursor reads

| Artifact | Path | Status |
| --- | --- | --- |
| Always-on map | `AGENTS.md` | **VERIFIED** docs: root AGENTS.md is loaded |
| Hard rules | `.cursor/rules/*.mdc` → `@rules/*.md` | **VERIFIED** docs: `.mdc` + `@file`; runtime injection **NOT VERIFIED** here |
| Skills | `.cursor/skills/**/SKILL.md` | **VERIFIED** docs: native discovery root |
| Commands | `.cursor/commands/*.md` | **INTENDED** (product still has `/` commands) |
| Subagents | `.cursor/agents/*.md` | **VERIFIED** docs: `.cursor/agents/`; isolation working **NOT VERIFIED** |

Do **not** also symlink `.agents/skills` or `.claude/skills` in this repo — Cursor cross-loads those roots and would duplicate skills.

## Rules

Portable meaning stays in `rules/*.md`. Cursor activation is thin `.mdc` files:

- hard / global → `alwaysApply: true`
- `simplest-correct` → `alwaysApply: false` + description (architecture tasks)

## Subagents vs skills

| Use subagent when | Use skill when |
| --- | --- |
| Isolated context, independent review | Repeatable procedure, on-demand method |
| Reviewer must not edit (`readonly: true`) | Single-purpose engineering workflow |

Orchestrator stays the parent session (`review-loop/models.md`). Two-model `model:` on Reviewer/Fixer: [`review-loop-models.md`](review-loop-models.md).

## Built-in Cursor skills

Product ships `/create-skill`, `/migrate-to-skills`, `/review`, subagent creators — separate from this repo’s skills.

## Thin by design

MCP, hooks, and marketplace stay out of the portable meaning. Verification and engineering methods stay in skills and `rules/`.

## References

- [`../README.md`](../README.md)
- `research/sources/cursor-docs-2026-09.md`
- `research/decisions/decision-009-cursor-native-layout.md`
- `research/validation/cursor-host-v2.md` (pre-restructure evidence)
