# Claude Code adapter

**Status:** implemented adapter (committed `CLAUDE.md` bridge + `b3 sync --host claude` + `b3 install product --host claude`). Live runtime discovery and subagent isolation in a fresh Claude Code session remain `UNKNOWN / INCOMPLETE` until independently observed and recorded.

> **Native binary:** Obtain `b3` once via [`../../scripts/bootstrap-b3.ps1`](../../scripts/bootstrap-b3.ps1) / [`../../scripts/bootstrap-b3.sh`](../../scripts/bootstrap-b3.sh) (zero-Rust checksum-verified bootstrapper) or `cargo build --release`.

## This repo → Claude Code

| Core | Claude Code mapping |
| --- | --- |
| `AGENTS.md` | Bridged by committed root [`CLAUDE.md`](../../CLAUDE.md) (`@AGENTS.md`) |
| `rules/*.md` | Referenced via `AGENTS.md` — same meaning, no duplicated prose |
| `skills/` + `adapters/command-skills/` | Gitignored flattened `.claude/skills/<name>` via `b3 sync --host claude` |
| `commands/` | Unified with skills via `adapters/command-skills/` in `.claude/skills/<name>` (Claude Code treats slash commands as skills — no duplicate `.claude/commands` link) |
| `agents/*.md` | Gitignored `.claude/agents` → `agents/` |

Review-loop roles: `b3-reviewer` (no edits), `b3-fixer` (no PASS), plus specialists. Optional `model:` overrides stay host-configured (`review-loop/models.md`). Orchestrator remains the parent conversation.

## Setup

### Inside this B3 checkout

Root `CLAUDE.md` works on fresh clone. Create the local gitignored `.claude/skills/<name>` (core `skills/` + `adapters/command-skills/`) and `.claude/agents` links:

```bash
b3 sync --host claude
b3 sync --host claude --verify-only
```

> **Coexistence note:** `b3 sync --host claude` refuses to run while `.cursor/skills` exists (Cursor cross-loads `.claude/skills` and duplicates skills) unless `--force` is passed.

### Separate product repository

```bash
b3 install product --product-root /path/to/product --host claude
```

Writes `.b3/home`, `AGENTS.md` and thin `CLAUDE.md` (`@AGENTS.md`, when missing), `.b3/ship/` + `.b3/research-ship/` + `.b3/pr-feedback/` + `.b3/models.md` + `.claude/skills` + `.claude/agents` in `.gitignore`, flattened `.claude/skills/<name>` junctions/symlinks (including `b3-ship`, `b3-research-ship`, `b3-plan`, `b3-implement`, `b3-debug`, `b3-review`, `b3-verify`, `b3-review-loop`, `b3-pr-resolve`, `b3-pr-reply`, `b3-pr-comment`), and `.claude/agents` → `{B3_HOME}/agents`.

## Host-native fallback & thin design

- Portable core skills keep simple `name:` fields and omit Claude-specific `allowed-tools` overlays.
- Hooks are optional and non-portable; the core must remain usable without hooks.
- When parallel subagent dispatch or isolation is unavailable in a Claude Code session, workflows fall back to `SEQUENTIAL` (`no_host_isolation` / `sequential_host_fallback` per [`../../workflows/references/dispatch-naming.md`](../../workflows/references/dispatch-naming.md)) and record `SINGLE_AGENT_LIMIT` / `UNKNOWN` where independent review is required.

## References

- [`../README.md`](../README.md)
- [`../../workflows/references/dispatch-naming.md`](../../workflows/references/dispatch-naming.md)
- `research/sources/claude-code-skills-plugins.md`
- `research/decisions/decision-013-host-neutral-multi-host-layout.md`
