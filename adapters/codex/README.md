# Codex adapter

**Status:** intended mapping only. No Codex-specific overlay is generated and this mapping has not been verified in this repository.

## This repo → Codex

| Core | Codex mapping |
| --- | --- |
| `AGENTS.md` | Primary operating file; merged chain subject to ~32 KiB default cap |
| `rules/*.md` | Include or link from `AGENTS.md` — do not duplicate prose |
| `.cursor/skills/` | Symlink → `.agents/skills/` via [`../sync-skills.sh`](../sync-skills.sh) |
| `.cursor/commands/` | Slash or prompt-style invocations when defined |
| `.cursor/agents/` | Role prompts (`reviewer`, `fixer`; optional specialists) |

Review-loop model slots stay host-configured (`review-loop/models.md`). Do not hard-code vendor model names in skill bodies.

Codex discovers `.agents/skills/` at repo root. Same layout as agentskills.io.

## AGENTS.md merge chain

Keep root `AGENTS.md` concise; defer procedures to skills.

If byte cap truncates context:
1. Shorten `AGENTS.md` to pointers
2. Rely on skill descriptions for activation
3. Split rarely-used docs to `docs/` + skill references

## Symlink

```bash
./adapters/sync-skills.sh codex
# creates .agents/skills → ../.cursor/skills
```

Do **not** run `all` while using Cursor in this repo if that would also create `.claude/skills` — Cursor cross-loads compatibility dirs.

## Thin by design

CLI flags and Codex-only config stay here. Core rules and skill procedures remain host-agnostic.

## References

- [`../README.md`](../README.md)
- `research/sources/openai-codex-customization.md`
- `research/sources/agentskills-open-standard.md`
