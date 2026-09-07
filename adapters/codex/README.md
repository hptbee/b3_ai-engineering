# Codex adapter

**Status:** intended mapping only. No Codex-specific overlays are generated yet.

## Portable core → Codex

| Core | Codex-oriented mapping (planned) |
| --- | --- |
| `AGENTS.md` | Primary operating file for Codex-style agents |
| `rules/` | Linked or included from `AGENTS.md`; do not duplicate text |
| `skills/*/SKILL.md` | Discoverable skills via `SKILL.md` frontmatter |
| `commands/` | Optional slash-style or prompt-style invocations when defined |
| `agents/` | Role prompts only when the agent layer exists |

## Thin by design

Codex-only instructions (CLI flags, local tool conventions) stay in this folder. They must not become core rules.
