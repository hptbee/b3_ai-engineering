# Codex adapter

**Status:** path matrix + sync script documented. No Codex-specific overlays generated yet.

## Portable core → Codex

| Core | Codex mapping |
| --- | --- |
| `AGENTS.md` | Primary operating file; merged chain subject to ~32 KiB default cap |
| `rules/*.md` | Include or link from `AGENTS.md` — do not duplicate prose |
| `skills/<name>/SKILL.md` | Symlink `skills/` → `.agents/skills/` via [`../sync-skills.sh`](../sync-skills.sh) |
| `commands/` | Slash or prompt-style invocations when defined |
| `agents/` | Role prompts when agent layer exists (`reviewer`, `fixer`; optional specialists) |

Review-loop model slots stay host-configured (`review-loop/models.md`). Do not hard-code vendor model names in portable files.

Codex discovers `.agents/skills/` at repo root (and user-level config outside repo). Same layout as agentskills.io standard.

## AGENTS.md merge chain

Codex merges multiple AGENTS files up the directory tree. Keep root `AGENTS.md` concise; defer procedures to skills (progressive disclosure).

If byte cap truncates context:
1. Shorten `AGENTS.md` to pointers
2. Rely on skill descriptions for activation
3. Split rarely-used docs to `docs/` + skill references

## Skills doc depth note

OpenAI/codex repo skills documentation may pointer to developers.openai.com — treat official web docs as authoritative when repo stub is thin (`research/README.md` deferred unknown).

## Symlink recommendation

```bash
./adapters/sync-skills.sh codex
# creates .agents/skills → ../skills
```

For Cursor + Codex on same repo:

```bash
./adapters/sync-skills.sh all
```

## Thin by design

CLI flags, local tool conventions, and Codex-only config stay here. Core rules and skills remain host-agnostic.

## References

- [`../README.md`](../README.md)
- `research/sources/openai-codex-customization.md`
- `research/sources/agentskills-open-standard.md`
