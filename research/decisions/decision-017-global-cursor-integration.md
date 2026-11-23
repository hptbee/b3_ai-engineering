# Decision 017 — Global Cursor Integration (`~/.cursor/`)

## Context

Cursor supports user-level global discovery under `~/.cursor/skills/`, `~/.cursor/commands/`, and `~/.cursor/agents/`, while User Rules are stored as plain text via Cursor Settings UI (`Settings > Rules > User Rules`, not a `~/.cursor/rules/*.mdc` folder). Cursor CLI has known limitations with nested skills/commands subdirectories compared with Cursor IDE, and Cursor cross-loads `~/.agents/skills/` and `~/.claude/skills/`. Previously, B3 required per-repo `install-product` or a single nested `~/.cursor/skills/b3-ai-engineering` junction without global commands, subagents, or global `B3_HOME` resolution.

## Decision

**ADOPT** dual-shell machine-wide installer scripts ([`adapters/cursor/install-global.ps1`](../../adapters/cursor/install-global.ps1) and [`adapters/cursor/install-global.sh`](../../adapters/cursor/install-global.sh)) supporting `install`, `update`, `verify`, `uninstall`, `--dry-run`/`-DryRun`, and `--force`/`-Force`:
- **Flattened 1-level skills (`~/.cursor/skills/<name>`):** link canonical `skills/*` only (excluding `adapters/command-skills/` so `/` menus avoid duplicate command skills) using unprivileged NTFS junctions on Windows and symlinks on POSIX.
- **Thin generated commands & subagents (`~/.cursor/commands/b3-*.md`, `~/.cursor/agents/b3-*.md`):** preserve canonical YAML frontmatter (including `model: inherit`), tag files with `b3-global-cursor-managed:`, and add global `~/.cursor/b3-home` fallback without duplicating procedures or model IDs.
- **User Rules fallback (`~/.cursor/b3-user-rules.txt`):** compact `<= 1,200 B` plain-text baseline explicitly instructing manual paste into Cursor Settings > Rules > User Rules, deferring to project `AGENTS.md` and `.cursor/rules/*.mdc`.
- **Safe manifest & coexistence (`~/.cursor/.b3-global-manifest`):** track managed entries by target path / SHA-256 so updates prune stale entries, conflicts refuse safely unless forced (including legacy `b3-ai-engineering` link migration), uninstall leaves unrelated user config untouched, and overlapping `~/.agents/skills/` / `~/.claude/skills/` emit `COEXISTENCE_WARNING:`.

## Consequences & tradeoffs

- **Zero always-on repo bloat:** `AGENTS.md`, `rules/`, `skills/`, and `always_on_total` (`14,940 B`) remain unchanged; `install-product` remains optional for shared project bindings.
- **Limitation (`UNKNOWN / INCOMPLETE`):** Automated validation (`scripts/validate-cursor-global.ps1`) verifies filesystem state, hashes, conflicts, spaces, and project isolation (`PASS`), whereas live Cursor IDE/CLI runtime activation and manual User Rules UI application cannot be executed in headless sandbox tests.
