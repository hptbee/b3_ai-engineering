# Cursor adapter

B3 keeps canonical rules, skills, commands, and agents in host-neutral root directories (`rules/`, `skills/`, `commands/`, `agents/`). Cursor can consume that single source of truth **globally (once per machine under `~/.cursor/`)** without touching unrelated repos, **per-repo via `install-product`**, or inside this B3 checkout via `sync-skills`.

## 1. Global installation (recommended, one-time per machine)

Installs under `~/.cursor/` via [`install-global.ps1`](install-global.ps1) / [`install-global.sh`](install-global.sh) (idempotent, dry-run safe, manifest-tracked `.b3-global-manifest`):
- **Skills (`~/.cursor/skills/<skill-name>`):** 1-level flattened junctions/symlinks to canonical `skills/*` (supports both Cursor IDE and Cursor CLI; excludes `adapters/command-skills/` to avoid duplicate `/` entries).
- **Commands (`~/.cursor/commands/b3-*.md`):** 8 thin generated entrypoints (`/b3-plan`, `/b3-implement`, `/b3-debug`, `/b3-review`, `/b3-verify`, `/b3-review-loop`, `/b3-ship`, `/b3-research-ship`) resolving `B3_HOME` globally via `~/.cursor/b3-home`.
- **Subagents (`~/.cursor/agents/b3-*.md`):** 5 generated role definitions (`b3-reviewer`, `b3-fixer`, `b3-security-reviewer`, `b3-architecture-reviewer`, `b3-performance-reviewer`) keeping `model: inherit` (no vendor model IDs).
- **Global Rules fallback (`~/.cursor/b3-user-rules.txt`):** compact plain-text baseline (`<= 1,200 B`) for **Cursor Settings > Rules > User Rules** (manual paste required — Cursor has no documented `~/.cursor/rules/*.mdc` directory).

### One-command CLI (`install`, `verify`, `update`, `uninstall`)

```powershell
# Windows PowerShell (creates unprivileged NTFS junctions; works with spaces)
.\adapters\cursor\install-global.ps1
.\adapters\cursor\install-global.ps1 verify
.\adapters\cursor\install-global.ps1 update
.\adapters\cursor\install-global.ps1 uninstall
```

```bash
# macOS / Linux / Git Bash
./adapters/cursor/install-global.sh
./adapters/cursor/install-global.sh verify
./adapters/cursor/install-global.sh update
./adapters/cursor/install-global.sh uninstall
```

To manage Cursor together with Antigravity from one shared canonical `B3_HOME`, you can also use the unified dispatcher ([`../install-global.ps1`](../install-global.ps1) / [`../install-global.sh`](../install-global.sh)) with `-HostName cursor` or `-HostName all` (`--host cursor|all`, supporting `-CursorHome`/`--cursor-home`, `-AntigravityPluginRoot`/`-PluginRoot`/`--plugin-root`, `-UserHome`/`--user-home`); see [`../antigravity/README.md`](../antigravity/README.md) for Antigravity checks.

**Optional model preferences:** The unified `../install-global.*` initializes `~/.b3/models.md` after a successful install/update, without overwriting existing preferences. If you use the direct Cursor installer above, copy [`../../config/models.example.md`](../../config/models.example.md) to `~/.b3/models.md` yourself. Preferences are advisory and loaded only on relevant dispatch; see [`../../docs/model-preferences.md`](../../docs/model-preferences.md).

- Pass `-DryRun` / `--dry-run` to preview changes without touching disk.
- Pass `-Force` / `--force` to replace conflicting same-named unmanaged files or migrate a legacy `~/.cursor/skills/b3-ai-engineering` link. Unrelated user files (`~/.cursor/skills/my-*`, custom commands/agents) are never removed or modified.

### Arbitrary-project usage examples

In any Git repo that has never run `install-product`:
- Type `/b3-plan`, `/b3-review`, `/b3-verify`, `/b3-debug`, `/b3-implement`, `/b3-review-loop`, `/b3-ship`, or `/b3-research-ship`.
- Let B3 resolve `B3_HOME` in order: `B3_HOME` env -> project `.b3/home` -> `~/.cursor/b3-home`.

## 2. Global vs. project-specific overrides

- **Project overrides win on project requirements:** repo `AGENTS.md`, `.cursor/rules/*.mdc`, `.cursor/skills/`, `.cursor/commands/`, and `.cursor/agents/` extend or override global B3 defaults.
- **`install-product` is optional:** only needed when a team wants repo-committed `.b3/home` and `.cursor/commands/*.md` shared via Git.
- **Migration:**
  - From legacy `~/.cursor/skills/b3-ai-engineering`: run `install-global.{ps1,sh} -Force` / `--force`.
  - From per-project `install-product`: project `.cursor/commands/b3-*.md` and `.b3/home` remain compatible alongside global `~/.cursor/`.

## 3. Alternative local/product modes

| Mode | Command | When |
| --- | --- | --- |
| Inside this B3 checkout | `.\adapters\sync-skills.ps1 -HostName cursor` / `./adapters/sync-skills.sh cursor` | Developing B3 itself |
| Optional per-project attach | [`../install-product.ps1`](../install-product.ps1) `-HostName cursor` / `--host cursor` | Team-committed repo pointer |

Do **not** also activate `.agents/skills` or `.claude/skills` in the same checkout — Cursor cross-loads those roots (`install-global` emits `COEXISTENCE_WARNING:` if overlapping `~/.agents/skills/` or `~/.claude/skills/` exist).

## 4. Known limitations & honest status

- **Global User Rules UI:** Cursor stores global User Rules in Cursor Settings (plain text); automatic script injection is not supported (`b3-user-rules.txt` must be pasted once manually).
- **Cursor CLI nesting:** Flattened 1-level skill links ensure compatibility with both Cursor IDE and CLI.
- **Filesystem vs. runtime verification:** Automated tests ([`../../scripts/validate-cursor-global.ps1`](../../scripts/validate-cursor-global.ps1)) verify links, SHA-256 hashes, conflicts, updates, paths with spaces, and clean uninstall (`PASS`), **not** live Cursor UI/CLI discovery (`UNKNOWN / INCOMPLETE` until exercised in Cursor).
- **Model overrides:** Orchestrator stays the parent session ([`../../review-loop/models.md`](../../review-loop/models.md)); optional Cursor `model:` notes live in [`review-loop-models.md`](review-loop-models.md).

## 5. Runtime smoke-test checklist (2 unrelated Cursor projects)

Run this manual check on two local Git repos (`repo-a`, `repo-b`) that have **never** run `install-product`:
1. Paste `~/.cursor/b3-user-rules.txt` into **Cursor Settings > Rules > User Rules**.
2. **Commands (`/b3-plan`, `/b3-verify`):** in `repo-a` and `repo-b`, confirm `/` shows `/b3-plan`..`/b3-ship` and resolves `B3_HOME` via `~/.cursor/b3-home` without creating `.b3/home` in the repo.
3. **Skills:** verify skill triggers (e.g., review/debugging) load from `~/.cursor/skills/<name>/SKILL.md` cleanly.
4. **Rules precedence:** add a temporary project rule in `repo-a/.cursor/rules/` or `repo-a/AGENTS.md` and confirm Cursor honors the project rule over personal defaults.
5. **Subagents:** invoke an independent review (`b3-reviewer` / `b3-security-reviewer`) and confirm isolated read-only findings return cleanly (if the host cannot isolate subagents, mark independence `UNKNOWN / INCOMPLETE` / `SINGLE_AGENT_LIMIT`).
6. Confirm `git status` in both repos has zero unexpected B3 files when finished.

## References

- [`../README.md`](../README.md)
- [`../../research/sources/cursor-docs-2026-09.md`](../../research/sources/cursor-docs-2026-09.md)
- [`../../research/decisions/decision-013-host-neutral-multi-host-layout.md`](../../research/decisions/decision-013-host-neutral-multi-host-layout.md)
- [`../../research/decisions/decision-017-global-cursor-integration.md`](../../research/decisions/decision-017-global-cursor-integration.md)
