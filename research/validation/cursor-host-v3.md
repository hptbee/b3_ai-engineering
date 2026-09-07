# Validation — Cursor host v3 (layout after decision-009)

- Date: 2026-09-07
- Scope: filesystem layout vs current Cursor docs. **Not** a new Agent session UI test.

## Claim

After moving skills/commands/agents onto Cursor discovery paths and adding `.cursor/rules/*.mdc`, a fresh clone no longer depends on a gitignored junction.

## Evidence (layout)

| Check | Result | How |
| --- | --- | --- |
| `.cursor/skills/**/SKILL.md` committed | 23 files | `git ls-files` |
| Repo-root `skills/` | Absent | filesystem |
| `.cursor/rules/*.mdc` | 5 files | filesystem |
| `.cursor/commands/*.md` | 6 commands + README | filesystem |
| `.cursor/agents/*.md` | 4 roles + README | filesystem |
| `.gitignore` ignores `.cursor/skills` | No | `.gitignore` |

## What this does **not** prove

| Claim | Status |
| --- | --- |
| Customize → Skills lists 23 B3 skills after a **new** Agent session | **NOT VERIFIED** |
| Hard rules inject via `@rules/*.md` | **INTENDED** (docs allow `@file`) |
| `/plan` etc. appear as slash commands | **INTENDED** |
| Subagents auto-delegate for independent review | **NOT VERIFIED** |

Pre-restructure junction evidence: `cursor-host-v2.md`.
