# Antigravity adapter

**Status:** implemented adapter; Antigravity runtime skill discovery, plugin loading, and subagent isolation are `UNKNOWN / INCOMPLETE` until independently observed in a fresh Antigravity session and recorded.

## This repo → Antigravity

| Core | Antigravity mapping |
| --- | --- |
| `AGENTS.md` | Native workspace rule (auto-loaded from repo root) |
| `rules/*.md` | Referenced via `AGENTS.md` in-repo, or generated into plugin `rules/AGENTS.md` (plain Markdown, no frontmatter, `< 24 KB`) |
| `skills/` | Committed `.agents/skills.json` (1-level category entries) in this repo; flattened `.agents/skills/<name>` junctions/symlinks in product repos (`install-product -HostName antigravity`), or inside plugin `skills/<name>` |
| `commands/` + `adapters/command-skills/` | Exposed as skills via `adapters/command-skills/` (`b3-ship`, `b3-plan`, `b3-implement`, `b3-debug`, `b3-review`, `b3-verify`, `b3-review-loop`) or natural prompt intent |
| `agents/*.md` | Generated into plugin `agents/<name>.md` (`subagent: true`, `mainAgent: false`, explicit least-privilege `tools:`), or dynamically delegated via `define_subagent` / `invoke_subagent` |

## Capability classification

| Antigravity mechanism | B3 use | Classification |
| --- | --- | --- |
| Root `AGENTS.md` | Durable project map and precedence | SUPPORTED |
| `.agents/skills.json` (`entries`) | One-level discovery over categorized `skills/*` and `adapters/command-skills` without duplicate copies | SUPPORTED |
| `.agents/skills/<name>/SKILL.md` | Flattened skill discovery in product repos | SUPPORTED |
| Global plugin (`~/.gemini/config/plugins/b3-ai-engineering/`) | Machine-wide bundle of rules, skills, and isolated subagents (`plugin.json`, `rules/AGENTS.md`, `skills/`, `agents/`) | SUPPORTED |
| Subagents (`agents/<name>.md` or dynamic `define_subagent`) | Review-loop isolation (`b3-reviewer`, `b3-fixer`, specialists) | SUPPORTED BY ANTIGRAVITY; B3 runtime isolation `UNKNOWN / INCOMPLETE` |
| Hooks (`hooks.json`), MCP (`mcp_config.json`) | Not required to preserve B3 meaning | SUPPORTED BUT UNNECESSARY FOR B3 |
| Runtime skill & plugin discovery in fresh session | Live end-to-end activation evidence | `UNKNOWN / INCOMPLETE` |

## Subagent tool mapping

When generating plugin agents from `agents/*.md`, `model:` and `readonly:` are mapped to Antigravity subagent frontmatter (`subagent: true`, `mainAgent: false`, explicit `tools:`):

| B3 role | Source `readonly` | Antigravity `tools` |
| --- | --- | --- |
| `b3-reviewer`, `b3-security-reviewer`, `b3-architecture-reviewer`, `b3-performance-reviewer` | `true` | `[read_file]` |
| `b3-fixer` | `false` | `[read_file, edit_file, write_file, run_command, manage_task]` |

## Setup modes

### 1. Working inside this B3 checkout

No symlink or junction is needed (and **do not** keep `.agents/skills` alongside `.agents/skills.json` if Antigravity opens this checkout — Antigravity reads both). This repository commits `.agents/skills.json` pointing one level above the categorized `skills/*` folders plus `adapters/command-skills`.

Verify the manifest resolves all `SKILL.md` entries:

```powershell
# Windows PowerShell
.\adapters\sync-skills.ps1 -HostName antigravity -VerifyOnly
```

```bash
# macOS / Linux
./adapters/sync-skills.sh --verify antigravity
```

To regenerate `.agents/skills.json` from the canonical skill tree:

```powershell
.\adapters\sync-skills.ps1 -HostName antigravity
```

```bash
./adapters/sync-skills.sh antigravity
```

### 2. Product repository attach

Attach B3 to a separate product repository without copying `skills/` into it:

```powershell
# Windows PowerShell
.\adapters\install-product.ps1 -ProductRoot D:\path\to\your-product -HostName antigravity
```

```bash
# macOS / Linux
./adapters/install-product.sh --product-root /path/to/your-product --host antigravity
```

This writes `{product}/.b3/home`, `{product}/AGENTS.md` (when missing), `.b3/ship/` + `.agents/skills` in `.gitignore`, and a gitignored flattened `.agents/skills/<name>` index (one junction/symlink per B3 skill plus command skills such as `b3-ship`).

> **Cursor coexistence:** If Cursor also opens that same product repository, do **not** create `.agents/skills` in the product repo (Cursor cross-loads `.agents/skills` and can duplicate skills). Instead, attach the product with `-HostName cursor` (or `--host cursor`) and install the **global Antigravity plugin** below.

### 3. Machine-global Antigravity plugin

Generate a self-contained Antigravity plugin under `~/.gemini/config/plugins/b3-ai-engineering/` so B3 rules, skills, and subagent roles are available across workspaces and toggleable as one unit:

```powershell
# Windows PowerShell
.\adapters\antigravity\install-plugin.ps1
.\adapters\antigravity\install-plugin.ps1 -DryRun
```

```bash
# macOS / Linux
./adapters/antigravity/install-plugin.sh
./adapters/antigravity/install-plugin.sh --dry-run
```

Enable, disable, or uninstall the plugin from the Antigravity Customizations UI (`[B3 AI Engineering](customization://b3-ai-engineering)`). Never hand-edit `~/.gemini/config/config.json`.

## Thin by design

`plugin.json`, `.agents/skills.json`, and Antigravity `tools:` mappings belong here or in generated plugin directories. Portable rules (`rules/*.md`), Agent Skills (`skills/`), commands (`commands/`), agents (`agents/`), workflows, and the review-loop specification stay host-agnostic.

## References

- [`../README.md`](../README.md)
- [`../../research/decisions/decision-011-product-repo-attach.md`](../../research/decisions/decision-011-product-repo-attach.md)
- [`../../research/decisions/decision-013-host-neutral-multi-host-layout.md`](../../research/decisions/decision-013-host-neutral-multi-host-layout.md)
