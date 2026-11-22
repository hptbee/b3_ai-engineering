# Adapters

B3 uses a **host-neutral canonical core** (`rules/`, `skills/`, `commands/`, `agents/`, `workflows/`, `review-loop/`) mapped onto **Cursor**, **Codex**, **Claude Code**, and **Antigravity** without duplicating prose.

Do **not** commit duplicate skill, command, or agent trees under `.cursor/`, `.agents/`, `.claude/`, or `.codex/`. Only thin committed entrypoints (`AGENTS.md`, `CLAUDE.md`, `.cursor/rules/*.mdc`, `.agents/skills.json`) are committed; local discovery links are gitignored and managed by `adapters/sync-skills.{ps1,sh}`.

## Host path matrix

| Host | Rules / context | Skills | Commands | Subagents |
| --- | --- | --- | --- | --- |
| **Cursor** | `AGENTS.md` + committed `.cursor/rules/*.mdc` (`@rules/*.md`) | Gitignored `.cursor/skills` → `skills/` (or `~/.cursor/skills/b3-ai-engineering` in products) | Gitignored `.cursor/commands` → `commands/` (product: `.cursor/commands/*.md`) | Gitignored `.cursor/agents` → `agents/` |
| **Codex** | `AGENTS.md` | Gitignored flattened `.agents/skills/<name>` (core `skills/` + `adapters/command-skills/`) | `adapters/command-skills/` (`$ship`, `$plan`, …) + prompt routing | Delegated role prompts from `agents/*.md` |
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

For a machine-global Antigravity plugin (`~/.gemini/config/plugins/b3-ai-engineering/`), use `adapters/antigravity/install-plugin.{ps1,sh}`. See [`antigravity/README.md`](antigravity/README.md).

Layout decision: [`../research/decisions/decision-013-host-neutral-multi-host-layout.md`](../research/decisions/decision-013-host-neutral-multi-host-layout.md) (supersedes `decision-009-cursor-native-layout.md`).
