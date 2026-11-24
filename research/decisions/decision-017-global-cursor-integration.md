# Decision 017 — Global Integration for Cursor (`~/.cursor/`) and Antigravity (`~/.gemini/config/plugins/`)

## Context

Both **Cursor** and **Antigravity** support machine-wide user configuration from one canonical `B3_HOME`, while keeping per-project overrides (`AGENTS.md`, `GEMINI.md`, `.cursor/rules/*.mdc`, `.agents/rules/`, `.agents/skills/`) authoritative when present:
- **Cursor:** discovers `~/.cursor/skills/`, `~/.cursor/commands/`, and `~/.cursor/agents/`, while storing plain-text User Rules in Cursor Settings UI (`Settings > Rules > User Rules`). Cursor cross-loads `~/.agents/skills/` and `~/.claude/skills/`, and Cursor CLI has known limits on nested skill/command subdirectories.
- **Antigravity:** discovers bundled plugins under `~/.gemini/config/plugins/<name>/` (`plugin.json`, `rules/AGENTS.md` `< 24 KB`, 1-level `skills/`, `agents/*.md` with `subagent: true`, `mainAgent: false`, explicit `tools:`), manages UI enable/disable state in `~/.gemini/config/config.json`, and loads `~/.gemini/config/skills/` and `~/.agents/skills/`.

Previously, B3 lacked a unified machine-global lifecycle (`install`, `update`, `verify`, `uninstall`, `--dry-run`) across both hosts, Antigravity's `.sh` plugin script relied on bare `ln -s` (failing unprivileged on Windows Git Bash), and neither plugin-drift/surface verification nor cross-host coexistence verification existed.

## Decision

**ADOPT** independent dual-shell host installers under one thin unified dispatcher (`adapters/install-global.{ps1,sh}` accepting `-HostName cursor|antigravity|all` / `--host cursor|antigravity|all`):
- **Cursor (`adapters/cursor/install-global.{ps1,sh}`):** links canonical `skills/*` into 1-level `~/.cursor/skills/<name>` (excluding `adapters/command-skills/`), generates thin `b3-global-cursor-managed:` entrypoints for all 7 commands and 5 `model: inherit` subagents with global `~/.cursor/b3-home` fallback, generates `<= 1,200 B` `b3-user-rules.txt` for manual UI paste, and tracks `~/.cursor/.b3-global-manifest`.
- **Antigravity (`adapters/antigravity/install-plugin.{ps1,sh}`):** generates and verifies `~/.gemini/config/plugins/b3-ai-engineering/` (`plugin.json` preserving the 5 supported top-level keys, `rules/AGENTS.md` with global `B3_HOME` and project-precedence header, 1-level links to `skills/*` + `adapters/command-skills/*`, `agents/*.md` without hardcoded models, and `.b3-plugin-manifest`), using unprivileged NTFS junctions on Windows (in both `.ps1` and `.sh`) and symlinks on POSIX, while never editing `config.json`.
- **Shared adapter primitives (`adapters/lib/global-common.{ps1,sh}`):** centralize path normalization, SHA-256 hashing, symlink/junction handling and safety boundaries, skill frontmatter discovery, and corruption-aware manifest I/O without adding external dependencies or changing CLI contracts.
- **Per-surface verification & coexistence guards:** `verify` validates manifest schemas, raw-byte SHA-256 parity across shells, target resolution, and per-surface health (`check.{plugin,rules,skills,commands,agents}` for Antigravity) and emits `COEXISTENCE_WARNING:` on overlapping loose skill or duplicate plugin roots without false-flagging Cursor + Antigravity side by side.

## Consequences & tradeoffs

- **Zero canonical duplication & zero repo bloat:** Both hosts share one canonical `B3_HOME`; `AGENTS.md`, `rules/`, `skills/`, and `always_on_total` (`14,940 B`) remain unchanged, and `install-product` stays optional.
- **Verification boundary (`UNKNOWN / INCOMPLETE`):** Automated suites ([`scripts/validate-cursor-global.ps1`](../../scripts/validate-cursor-global.ps1) and [`scripts/validate-antigravity-global.ps1`](../../scripts/validate-antigravity-global.ps1)) verify filesystem generation, Windows NTFS junctions, byte-identical hashes across PowerShell and Git Bash, conflicts, paths with spaces, unrelated repo isolation, and uninstall (`PASS`), whereas native macOS/Linux `.sh` symlink (`ln -s`) execution and live Cursor/Antigravity IDE/CLI runtime activation require live checks on target hosts.
