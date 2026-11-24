# Adapters

B3 uses a **host-neutral canonical core** (`rules/`, `skills/`, `commands/`, `agents/`, `workflows/`, `review-loop/`) mapped onto **Cursor**, **Codex**, **Claude Code**, and **Antigravity** without duplicating prose.

Do **not** commit duplicate skill, command, or agent trees under `.cursor/`, `.agents/`, `.claude/`, or `.codex/`. Only thin committed entrypoints (`AGENTS.md`, `CLAUDE.md`, `.cursor/rules/*.mdc`, `.agents/skills.json`) are committed; local discovery links are gitignored and managed by `adapters/sync-skills.{ps1,sh}`.

## Host path matrix

| Host | Rules / context | Skills | Commands | Subagents |
| --- | --- | --- | --- | --- |
| **Cursor** | `AGENTS.md` + committed `.cursor/rules/*.mdc` (`@rules/*.md`) | Gitignored `.cursor/skills` → `skills/` (or `~/.cursor/skills/b3-ai-engineering` in products) | Gitignored `.cursor/commands` → `commands/` (product: `.cursor/commands/*.md`) | Gitignored `.cursor/agents` → `agents/` |
| **Codex** | `AGENTS.md` | Gitignored flattened `.agents/skills/<name>` (core `skills/` + `adapters/command-skills/`) | `adapters/command-skills/` (`$b3-ship`, `$b3-plan`, …) + prompt routing | Delegated role prompts from `agents/*.md` |
| **Claude Code** | Committed `CLAUDE.md` (`@AGENTS.md`) | Gitignored flattened `.claude/skills/<name>` (core `skills/` + `adapters/command-skills/`) | Unified with skills (`adapters/command-skills/` via `.claude/skills/<name>`) | Gitignored `.claude/agents` → `agents/` |
| **Antigravity** | `AGENTS.md` (or plugin `rules/AGENTS.md`) | Committed `.agents/skills.json` (in-repo), flattened `.agents/skills/<name>` (product), or plugin `skills/` | `adapters/command-skills/` via `.agents/skills.json` / plugin | Generated plugin `agents/*.md` (`subagent: true`, explicit `tools:`) or dynamic `define_subagent` |

## Per-host docs

| Adapter | File |
| --- | --- |
| Cursor | [`cursor/README.md`](cursor/README.md) |
| Codex | [`codex/README.md`](codex/README.md) |
| Claude Code | [`claude/README.md`](claude/README.md) |
| Antigravity | [`antigravity/README.md`](antigravity/README.md) |

## Local checkout activation (`sync-skills`)

```powershell
# Windows PowerShell (creates NTFS junctions; no dev-mode symlink privilege required)
.\adapters\sync-skills.ps1 -HostName cursor
.\adapters\sync-skills.ps1 -HostName codex
.\adapters\sync-skills.ps1 -HostName claude
.\adapters\sync-skills.ps1 -HostName antigravity -VerifyOnly
```

```bash
# macOS / Linux
./adapters/sync-skills.sh cursor
./adapters/sync-skills.sh codex
./adapters/sync-skills.sh claude
./adapters/sync-skills.sh --verify antigravity
```

- Supports `--dry-run` / `-DryRun`, `--verify` / `-VerifyOnly`, and `--force` / `-Force`.
- **Coexistence guards:** `sync-skills` refuses (unless `-Force` / `--force`) to create `.cursor/skills` alongside `.agents/skills` or `.claude/skills` (Cursor cross-loads those roots and duplicates skills), and warns when `.agents/skills` coexists with committed `.agents/skills.json` (Antigravity reads both). There is intentionally no unguarded `all` target.
- Both helpers **exit 1** on missing sources, wrong links, or non-empty non-link content. Filesystem success is not runtime host-discovery `PASS`.

## Product repository attach (`install-product`)

B3 drives work in a separate product repository without copying `skills/`:

```powershell
# Windows
.\adapters\install-product.ps1 -ProductRoot D:\path\to\product -HostName cursor
.\adapters\install-product.ps1 -ProductRoot D:\path\to\product -HostName codex
.\adapters\install-product.ps1 -ProductRoot D:\path\to\product -HostName claude
.\adapters\install-product.ps1 -ProductRoot D:\path\to\product -HostName antigravity
```

```bash
# macOS / Linux
./adapters/install-product.sh --product-root /path/to/product --host cursor
./adapters/install-product.sh --product-root /path/to/product --host codex
./adapters/install-product.sh --product-root /path/to/product --host claude
./adapters/install-product.sh --product-root /path/to/product --host antigravity
```

Writes `{product}/.b3/home`, `{product}/AGENTS.md` (when missing), `{product}/.cursor/commands/*.md`, and `.b3/ship/` in `.gitignore`. Host specifics:
- **cursor:** refuses existing `.agents/skills` or `.claude/skills`; writes `.cursor/README.md`.
- **codex / antigravity:** writes gitignored flattened `.agents/skills/<name>` (core `skills/` + `adapters/command-skills/`).
- **claude:** writes thin `CLAUDE.md` (`@AGENTS.md`, when missing), gitignored flattened `.claude/skills/<name>`, and gitignored `.claude/agents` → `{B3_HOME}/agents`.

## Machine-global installation (`install-global`)

Install, verify, update, or uninstall global B3 integration across **Cursor** (`~/.cursor/`), **Antigravity** (`~/.gemini/config/plugins/b3-ai-engineering/`), or both from one canonical `B3_HOME`:

```powershell
# Windows PowerShell
.\adapters\install-global.ps1 -HostName cursor
.\adapters\install-global.ps1 -HostName antigravity
.\adapters\install-global.ps1 -HostName all
.\adapters\install-global.ps1 verify -HostName all
```

```bash
# macOS / Linux / Git Bash
./adapters/install-global.sh --host cursor
./adapters/install-global.sh --host antigravity
./adapters/install-global.sh --host all
./adapters/install-global.sh verify --host all
```

Host-specific installers ([`cursor/install-global.ps1`](cursor/install-global.ps1) / [`cursor/install-global.sh`](cursor/install-global.sh) and [`antigravity/install-plugin.ps1`](antigravity/install-plugin.ps1) / [`antigravity/install-plugin.sh`](antigravity/install-plugin.sh)) stay independent, share filesystem/hashing/manifest/discovery primitives via [`lib/global-common.ps1`](lib/global-common.ps1) / [`lib/global-common.sh`](lib/global-common.sh), support `install`, `verify`, `update`, `uninstall`, `-DryRun`/`--dry-run`, and `-Force`/`--force`, and are documented in [`cursor/README.md`](cursor/README.md) and [`antigravity/README.md`](antigravity/README.md).

Layout decision: [`../research/decisions/decision-013-host-neutral-multi-host-layout.md`](../research/decisions/decision-013-host-neutral-multi-host-layout.md) (supersedes `decision-009-cursor-native-layout.md`), global host integration: [`../research/decisions/decision-017-global-cursor-integration.md`](../research/decisions/decision-017-global-cursor-integration.md).
