# Codex adapter

**Status:** implemented adapter; live runtime skill discovery in a fresh Codex session remains `UNKNOWN / INCOMPLETE` until observed and recorded (`research/validation/codex-host-v1.md`).

## This repo → Codex

| Core | Codex mapping |
| --- | --- |
| `AGENTS.md` | Primary operating file; merged chain subject to ~32 KiB default cap |
| `rules/*.md` | Referenced from `AGENTS.md` — do not duplicate prose |
| `skills/` | Exposed through gitignored flattened `.agents/skills/<name>` via [`../sync-skills.ps1`](../sync-skills.ps1) / [`../sync-skills.sh`](../sync-skills.sh) |
| `commands/` + `adapters/command-skills/` | Exposed as `$ship`, `$plan`, `$implement`, `$debug`, `$review`, `$verify`, `$review-loop` in `.agents/skills/<name>` + prompt routing |
| `agents/*.md` | Role prompt source for delegated reviewer/fixer/security/architecture/performance work |

Review-loop model slots stay host-configured (`review-loop/models.md`). Do not hard-code vendor model names in skill bodies.

## Setup

### Inside this B3 checkout

Create the local gitignored flattened `.agents/skills/<name>` index (core `skills/` + `adapters/command-skills/`):

```powershell
# Windows
.\adapters\sync-skills.ps1 -HostName codex
.\adapters\sync-skills.ps1 -HostName codex -VerifyOnly
```

```bash
# macOS / Linux
./adapters/sync-skills.sh codex
./adapters/sync-skills.sh --verify codex
```

> **Coexistence notes:**
> - `sync-skills codex` refuses to run while `.cursor/skills` exists (Cursor cross-loads `.agents/skills` and duplicates skills) unless `-Force` / `--force` is passed.
> - This repo also commits `.agents/skills.json` for Antigravity. If Antigravity opens the same checkout while `.agents/skills/` exists, Antigravity may read both.

### Separate product repository

```powershell
.\adapters\install-product.ps1 -ProductRoot D:\path\to\product -HostName codex
```

```bash
./adapters/install-product.sh --product-root /path/to/product --host codex
```

Writes `.b3/home`, thin `AGENTS.md` (when missing), `.b3/ship/` + `.agents/skills` in `.gitignore`, and a gitignored flattened `.agents/skills/<name>` index (one junction/symlink per B3 skill plus command skills such as `ship`).

## Command and role routing

- `ship` on Codex is `$ship` (`adapters/command-skills/ship/SKILL.md`), installed as `.agents/skills/ship`. It routes directly in 1 hop to `{B3_HOME}/workflows/ship.md` without an intermediate `commands/ship.md` hop or duplicating the procedure.
- For review-loop delegation, pass `agents/reviewer.md`, `fixer.md`, `security-reviewer.md`, `architecture-reviewer.md`, or `performance-reviewer.md` to an isolated delegated agent when available. Parent remains orchestrator.

## Thin by design

CLI flags and Codex-only config stay here. Core rules and skill procedures remain host-agnostic.

## References

- [`../README.md`](../README.md)
- `research/sources/openai-codex-customization.md`
- `research/decisions/decision-013-host-neutral-multi-host-layout.md`
