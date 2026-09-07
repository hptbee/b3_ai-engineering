# Decision 009 — Cursor-native layout (first host)

## Context

B3’s portable core lived at repo-root `skills/`, `commands/`, `agents/`, and `rules/*.md`. Cursor does not discover those folders. Discovery required a gitignored junction (`.cursor/skills` → `skills/`), so a fresh clone did not load skills. Rules were never `.mdc`. Commands and agents were not on Cursor discovery paths.

Cursor is the first real host. Decision-002 (portable core + thin adapters) remains the content rule. This decision amends **where** Cursor-consumed artifacts live.

## Observed

- Cursor skills: `.cursor/skills/`, `.agents/skills/` ([cursor.com/docs/skills](https://cursor.com/docs/skills); `research/sources/cursor-docs-2026-09.md`)
- Cursor rules: `.cursor/rules/*.mdc` only; `.md` ignored ([cursor.com/docs/rules](https://cursor.com/docs/rules))
- Cursor subagents: `.cursor/agents/` ([cursor.com/docs/subagents](https://cursor.com/docs/subagents))
- Windows: committed git symlinks are unreliable; the previous junction was gitignored
- Validation: `research/validation/cursor-host-v2.md` — discovery worked only after a local junction

## Constraint

Minimum duplication + maximum reliability in Cursor. Keep Agent Skills / rule / review-loop **meaning** portable. Do not invent a generator that copies the whole tree. Do not require a setup script before Cursor works.

## Options

1. Keep root `skills/` and keep a gitignored junction (status quo) — fresh clone fails
2. Keep root `skills/` and commit generated copies under `.cursor/skills/` — duplicate trees
3. Canonical skills/commands/agents in `.cursor/`; portable `rules/*.md` bodies; thin `.mdc` activation
4. Move everything including rule bodies into `.cursor/` and drop portable `rules/`

## Trade-off

(3) puts skill files in a host-named folder. Format stays Agent Skills. Other hosts map from `.cursor/skills` via adapters. (4) would force Codex/Claude to parse `.mdc`. (2) drifts.

## Decision

**ADOPT option 3.**

| Artifact | Canonical location | Cursor activation |
| --- | --- | --- |
| Skills | `.cursor/skills/` (committed SKILL.md trees) | Native discovery |
| Commands | `.cursor/commands/` | Native `/` commands |
| Agents | `.cursor/agents/` | Native subagents |
| Rule bodies | `rules/*.md` | `.cursor/rules/*.mdc` `@`-include, alwaysApply (hard) or description (strong) |
| Review-loop spec | `review-loop/spec.md` | Loaded by command / strategy, not a host plugin |
| Docs / research / evals / knowledge | unchanged roles | Not configuration |

This amends decision-002 consequence “do not copy skills into `.cursor/skills`” — the files **are** the skill corpus; they are not a second copy. Adapters for Codex/Claude symlink **from** `.cursor/skills`, not the reverse.

## Consequences

- No `skills/`, `commands/`, or `agents/` at repo root
- `.cursor/skills` is not gitignored
- `adapters/sync-skills.sh` exports to other hosts only
- Portability means content format and meaning, not “must live outside `.cursor/`”

## Confidence

High on discovery paths (official docs). **NOT VERIFIED** in this change: auto-activation of skills in a new Agent session; slash-command UX for `.cursor/commands`.
