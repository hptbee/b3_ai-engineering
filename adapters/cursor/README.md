# Cursor adapter

B3 keeps canonical rules, skills, commands, and agents in host-neutral root directories (`rules/`, `skills/`, `commands/`, `agents/`). Cursor activates rules natively via committed `.cursor/rules/*.mdc` (`@rules/*.md`) and `AGENTS.md`, and activates skills, commands, and agents via local gitignored links created by `adapters/sync-skills.{ps1,sh} cursor`.

## What Cursor reads

| Artifact | Path | Activation |
| --- | --- | --- |
| Always-on map | `AGENTS.md` | Committed at repo root |
| Hard / strong rules | `.cursor/rules/*.mdc` → `@rules/*.md` | Committed thin wrappers |
| Skills | `.cursor/skills` → `skills/` | Gitignored link (`sync-skills cursor`) |
| Commands | `.cursor/commands` → `commands/` | Gitignored link (`sync-skills cursor`) |
| Subagents | `.cursor/agents` → `agents/` | Gitignored link (`sync-skills cursor`) |

## Setup

### Inside this B3 checkout

```powershell
# Windows
.\adapters\sync-skills.ps1 -HostName cursor
.\adapters\sync-skills.ps1 -HostName cursor -VerifyOnly
```

```bash
# macOS / Linux
./adapters/sync-skills.sh cursor
./adapters/sync-skills.sh --verify cursor
```

Do **not** also activate `.agents/skills` or `.claude/skills` in the same checkout — Cursor cross-loads those roots and duplicates skills (`sync-skills` enforces this coexistence guard unless `-Force` / `--force` is passed).

### Separate product repository

Run [`../install-product.ps1`](../install-product.ps1) (or `.sh`) with `-HostName cursor` / `--host cursor`. That writes `.b3/home`, `AGENTS.md` (when missing), `.cursor/commands/*.md`, and `.gitignore` `.b3/ship/`. It does **not** copy `skills/` into the product. Optional user-level link (once per machine):

```powershell
# Windows
cmd /c mklink /J "$env:USERPROFILE\.cursor\skills\b3-ai-engineering" "D:\path\to\b3_ai-engineering\skills"
```

```bash
# macOS / Linux
ln -sfn /path/to/b3_ai-engineering/skills ~/.cursor/skills/b3-ai-engineering
```

## Rules & Subagents

- Portable meaning stays in `rules/*.md`; `.cursor/rules/*.mdc` only carries `alwaysApply` and `description`.
- Orchestrator stays the parent session (`review-loop/models.md`). Two-model `model:` override notes: [`review-loop-models.md`](review-loop-models.md).

## References

- [`../README.md`](../README.md)
- `research/sources/cursor-docs-2026-09.md`
- `research/decisions/decision-013-host-neutral-multi-host-layout.md`
