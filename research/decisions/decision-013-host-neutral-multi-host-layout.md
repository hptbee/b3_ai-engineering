# Decision 013 — Host-neutral multi-host layout (Cursor, Codex, Claude Code, Antigravity)

## Status

**ADOPT** — supersedes [`decision-009-cursor-native-layout.md`](decision-009-cursor-native-layout.md); restores and refines [`decision-002-portability.md`](decision-002-portability.md) for four equal first-class hosts.

## Context

Decision-009 placed canonical skills, commands, and agents under `.cursor/` when Cursor was the only active host, prioritizing zero-setup discovery in Cursor over host-neutral paths.

B3 now actively targets **four** hosts: **Cursor**, **Codex**, **Claude Code**, and **Antigravity**. Keeping canonical skills, commands, and agents inside `.cursor/` created asymmetric naming (e.g., `adapters/codex-command-skills/`, `.agents/skills.json` pointing into `.cursor/skills/`), forced non-Cursor hosts to reference Cursor-branded paths, and left Claude Code without a committed root bridge (`CLAUDE.md`) or symmetric adapter tooling.

## Constraint

- Single source of truth: no duplicated skill, rule, command, or agent prose across host folders.
- Equal first-class activation for Cursor, Codex, Claude Code, and Antigravity (both inside this checkout and via `adapters/install-product.{ps1,sh}` for separate product repositories).
- Explicit coexistence guards so hosts do not double- or triple-discover skills in the same checkout (Cursor cross-loads `.agents/skills` and `.claude/skills`; Antigravity reads both `.agents/skills.json` and `.agents/skills`).
- `simplest-correct`: avoid duplicate command surfaces per host (e.g., Claude Code unifies slash commands as skills, so `.claude/skills/<name>` covers both core skills and `adapters/command-skills/` without a second `.claude/commands` link).

## Decision

Move canonical artifacts to host-neutral repo-root directories and activate each host via thin committed wrappers/manifests or gitignored local links:

| Artifact | Canonical location | Host activation |
| --- | --- | --- |
| Always-on map | `AGENTS.md` | Native in Cursor, Codex, Antigravity; bridged by committed `CLAUDE.md` (`@AGENTS.md`) for Claude Code |
| Rule bodies | `rules/*.md` | Cursor: committed `.cursor/rules/*.mdc` (`@rules/*.md`); others: via `AGENTS.md` / plugin `rules/AGENTS.md` |
| Skills | `skills/<category>/<name>/SKILL.md` | Cursor: gitignored `.cursor/skills` → `skills`; Codex: gitignored flattened `.agents/skills/<name>`; Claude: gitignored flattened `.claude/skills/<name>`; Antigravity: committed `.agents/skills.json` (1-level category entries) or global plugin |
| Commands | `commands/*.md` + `adapters/command-skills/<name>/SKILL.md` | Cursor: gitignored `.cursor/commands` → `commands`; Codex/Claude/Antigravity: `adapters/command-skills/` exposed via each host's skill surface |
| Subagents | `agents/*.md` | Cursor: gitignored `.cursor/agents` → `agents`; Claude: gitignored `.claude/agents` → `agents`; Antigravity: generated plugin `agents/*.md` (`subagent: true`, explicit `tools:`) or dynamic subagents; Codex: delegated role prompts |

## Trade-off

- **Reversed from Decision-009:** Cursor no longer discovers skills/commands/agents on a fresh clone without running `./adapters/sync-skills.{ps1,sh} cursor` (while `.cursor/rules/*.mdc` and `AGENTS.md` still activate on fresh clone). This one-time local link step is accepted in exchange for a truly host-neutral canonical core and symmetric 4-host tooling.
- **Preserved from Decision-009:** Zero duplicated prose; Windows uses NTFS junctions (no developer-mode symlink privilege required); product repos still attach via `.b3/home` without copying `skills/`.

## Consequences

- `.cursor/skills`, `.cursor/commands`, `.cursor/agents`, `.agents/skills`, `.claude/skills`, `.claude/agents`, and `.codex/skills` are gitignored local links managed by `adapters/sync-skills.{ps1,sh}`.
- `.cursor/rules/*.mdc`, `CLAUDE.md`, and `.agents/skills.json` remain committed thin host entrypoints.
- `adapters/codex-command-skills/` is renamed to `adapters/command-skills/`.
- `adapters/sync-skills.{ps1,sh}` adds `cursor` alongside `codex`, `claude`, and `antigravity`, and enforces coexistence guards unless `-Force` / `--force` is passed.
- Historical records under `research/decisions/decision-001..012` and `research/validation/` are preserved as provenance, not rewritten.
