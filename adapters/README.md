# Adapters

**Status:** Track C — path matrix and sync helper implemented. Hooks, generated manifests, and CI sync are **partial**.

Portable core lives at repo root (`AGENTS.md`, `rules/`, `skills/`, `docs/`). Adapters map that core to host discovery paths without forking content.

## Host path matrix

| Host | Skills discovery | Rules / standing instructions | Project context | Subagents / roles |
| --- | --- | --- | --- | --- |
| **Cursor** | `.cursor/skills/`, `.agents/skills/`, also loads `.claude/skills/`, `.codex/skills/` | `.cursor/rules/*.mdc` or user rules | `AGENTS.md` (nested supported) | `.cursor/agents/` |
| **Codex** | `.agents/skills/` (repo + user config) | Linked from `AGENTS.md`; byte cap ~32 KiB chain | `AGENTS.md` primary | Role prompts when defined |
| **Claude Code** | `.claude/skills/` | Claude rules / `CLAUDE.md` instructions | `CLAUDE.md` → bridge to `AGENTS.md` | `.claude/agents/` |

**Portable symlink target:** repo-root `skills/` → host skill folder (see `sync-skills.sh`).

Do **not** commit duplicate skill trees under multiple host folders unless generated from one source.

## Per-host docs

| Adapter | File |
| --- | --- |
| Cursor | [`cursor/README.md`](cursor/README.md) |
| Codex | [`codex/README.md`](codex/README.md) |
| Claude Code | [`claude/README.md`](claude/README.md) |

## Sync helper

```bash
./adapters/sync-skills.sh cursor    # symlink skills/ → .cursor/skills
./adapters/sync-skills.sh codex     # symlink skills/ → .agents/skills
./adapters/sync-skills.sh claude      # symlink skills/ → .claude/skills
./adapters/sync-skills.sh all       # all of the above
./adapters/sync-skills.sh --dry-run all
```

Symlinks keep a single source of truth. Run from repo root. Existing non-symlink directories are skipped with a warning.

## Host-specific extensions (adapter-only)

These must **not** appear in portable `skills/` frontmatter as required fields:

| Extension | Host | Notes |
| --- | --- | --- |
| `paths` / `globs` | Cursor | Auto-scope skills to subtrees |
| `disable-model-invocation` | Cursor | Human-only slash invocation |
| `icon`, `color` | Cursor | UI metadata |
| `allowed-tools` | Claude plugins / some OSS skills | Tool allowlists — document in adapter, optional in generated overlays |
| Hooks / SessionStart | Claude plugins, some Cursor setups | Enforcement layer; optional |
| `CLAUDE.md` | Claude Code | Generate pointer, not duplicate handbook |

## CLAUDE.md bridge (recommended)

When Claude Code requires root `CLAUDE.md`, generate:

```markdown
# Project instructions

Follow @AGENTS.md for operating context. Skills and rules live in the portable core; do not fork policy here.
```

Keep engineering method in `AGENTS.md` + `rules/` + `skills/`.

## Deferred

- Automated adapter CI (verify symlinks, diff check)
- Rule `.mdc` generation from `rules/*.md`
- Hook wrappers for review-loop gates
- Marketplace / team publishing paths

See `research/decisions/decision-002-portability.md` and `research/comparisons/portability.md`.
