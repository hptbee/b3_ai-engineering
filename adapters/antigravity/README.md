# Antigravity adapter

**Status:** implemented adapter; Antigravity runtime skill discovery, plugin loading, and subagent isolation remain `UNKNOWN / INCOMPLETE` until independently observed in a fresh Antigravity session and recorded.

## This repo → Antigravity

| Core | Antigravity mapping |
| --- | --- |
| `AGENTS.md` | Native workspace rule (auto-loaded from repo root) |
| `rules/*.md` | Referenced via `AGENTS.md` in-repo, or bundled into plugin `rules/AGENTS.md` (plain Markdown, no frontmatter, `< 24 KB`, with global `B3_HOME` and project-precedence header) |
| `skills/` | Committed `.agents/skills.json` (in this repo), flattened `.agents/skills/<name>` (`install-product -HostName antigravity`), or global `~/.gemini/config/skills.json` category entries + plugin `skills/<name>` links |
| `commands/` + `adapters/command-skills/` | Exposed as command skills (`b3-plan`, `b3-implement`, `b3-debug`, `b3-review`, `b3-verify`, `b3-review-loop`, `b3-ship`, `b3-research-ship`, `b3-pr-resolve`, `b3-pr-reply`, `b3-pr-comment`) inside `~/.gemini/config/skills.json`, plugin `skills/`, or `.agents/` |
| `agents/*.md` | Rendered into plugin `agents/<name>.md` (`subagent: true`, `mainAgent: false`, least-privilege `tools:`, zero hardcoded models), or dynamically delegated via `define_subagent` / `invoke_subagent` |

## Capability classification

| Antigravity mechanism | B3 use | Classification |
| --- | --- | --- |
| Root `AGENTS.md` / `GEMINI.md` | Durable project map and precedence | SUPPORTED |
| `.agents/skills.json` (`entries`) | One-level discovery over categorized `skills/*` and `adapters/command-skills` in this repo | SUPPORTED |
| `.agents/skills/<name>/SKILL.md` | Optional flattened per-product skill discovery | SUPPORTED |
| Global plugin (`~/.gemini/config/plugins/b3-ai-engineering/`) + global `~/.gemini/config/skills.json` | Machine-wide bundle (`plugin.json`, `rules/AGENTS.md`, `skills/`, `agents/`, `.b3-plugin-manifest`) plus `skills.json` real-directory entries for Antigravity's 1-level scanner across workspaces | SUPPORTED |
| Subagents (`agents/<name>.md` or dynamic `define_subagent`) | Review-loop isolation (`b3-reviewer`, `b3-fixer`, specialists) | SUPPORTED BY ANTIGRAVITY; B3 runtime isolation `UNKNOWN / INCOMPLETE` |
| Hooks (`hooks.json`), MCP (`mcp_config.json`) | Not required to preserve B3 meaning | SUPPORTED BUT UNNECESSARY FOR B3 |
| Live Antigravity runtime discovery across projects | End-to-end activation evidence in Antigravity IDE/CLI | `UNKNOWN / INCOMPLETE` |

## Subagent tool mapping

Canonical `agents/*.md` frontmatter maps to Antigravity subagent frontmatter (`subagent: true`, `mainAgent: false`, explicit `tools:`, no hardcoded model IDs):

| B3 role | Source `readonly` | Antigravity `tools` |
| --- | --- | --- |
| `b3-reviewer`, `b3-security-reviewer`, `b3-architecture-reviewer`, `b3-performance-reviewer` | `true` | `[read_file]` |
| `b3-fixer` | `false` | `[read_file, edit_file, write_file, run_command, manage_task]` |

## 1. Global installation (recommended, one-time per machine)

Generates and manages `~/.gemini/config/plugins/b3-ai-engineering/` and registers B3's real skill category directories plus `adapters/command-skills` in `~/.gemini/config/skills.json` from one canonical `B3_HOME` without copying framework prose or modifying unrelated projects. Works across all local repositories without running `install-product` (custom `entries`, `inherits`, and extra keys in `skills.json` are preserved on install, update, and uninstall).

### One-command CLI (`install`, `verify`, `update`, `uninstall`)

Use either the unified host dispatcher or the standalone plugin manager:

```powershell
# Windows PowerShell (unified dispatcher: antigravity, cursor, or all)
.\adapters\install-global.ps1 -HostName antigravity
.\adapters\install-global.ps1 -HostName all

# Direct plugin manager (install, verify, update, uninstall)
.\adapters\antigravity\install-plugin.ps1
.\adapters\antigravity\install-plugin.ps1 verify
.\adapters\antigravity\install-plugin.ps1 update
.\adapters\antigravity\install-plugin.ps1 uninstall
```

```bash
# macOS / Linux / Git Bash (unified dispatcher)
./adapters/install-global.sh --host antigravity
./adapters/install-global.sh --host all

# Direct plugin manager
./adapters/antigravity/install-plugin.sh install
./adapters/antigravity/install-plugin.sh verify
./adapters/antigravity/install-plugin.sh update
./adapters/antigravity/install-plugin.sh uninstall
```

**Optional model preferences:** The unified `../install-global.*` initializes `~/.b3/models.md` on successful install/update and preserves it on later updates/uninstall. With the direct plugin installer above, copy [`../../config/models.example.md`](../../config/models.example.md) to `~/.b3/models.md` manually. Model selection remains native/advisory; see [`../../docs/model-preferences.md`](../../docs/model-preferences.md).

- Pass `-DryRun` / `--dry-run` to preview `install` or `uninstall` without modifying disk.
- Normal `install`/`update` checks SHA-256 values recorded in `.b3-plugin-manifest` **before writing**. Modified generated files cause `UPDATE_CONFLICT` and are preserved. Back up your edits before using `-Force` / `--force` to deliberately replace same-named generated files or skill directories.
- Untracked symlinks and custom agents are never pruned; an untracked symlink colliding with a desired B3 skill name must be moved manually, even with `-Force`.
- Custom target/path flags (for sandboxes or non-default homes): `-PluginRoot` / `--plugin-root`, `-B3Home` / `--b3-home`, and `-UserHome` / `--user-home` (or `-AntigravityPluginRoot` / `-PluginRoot` and `-CursorHome` via `adapters/install-global.ps1`, `--plugin-root` and `--cursor-home` via `adapters/install-global.sh`).
- `verify` checks each capability surface independently (`check.plugin`, `check.rules`, `check.skills`, `check.commands`, `check.agents`, `check.skills_json`), hashes `plugin.json`, `rules/AGENTS.md`, and `agents/*.md` against canonical `B3_HOME` to detect drift, validates `~/.gemini/config/skills.json` B3 entries plus Windows NTFS junctions / POSIX symlinks, and scans for duplicate roots (`COEXISTENCE_WARNING:`).

### Arbitrary-project usage examples

In any local repository that has never run `install-product`:
- Invoke `/b3-plan`, `/b3-implement`, `/b3-debug`, `/b3-review`, `/b3-verify`, `/b3-review-loop`, `/b3-ship`, `/b3-research-ship`, `/b3-pr-resolve`, `/b3-pr-reply`, or `/b3-pr-comment` (or describe the workflow intent).
- Bundled `rules/AGENTS.md` supplies the global `B3_HOME` fallback when neither `B3_HOME` env nor product `.b3/home` exists, so canonical `workflows/ship.md`, `review-loop/strategy.md`, `scripts/b3-guard.*`, and skills resolve cleanly.

## 2. Global vs. project-specific behavior & coexistence

- **Project scope wins:** Repository-level `AGENTS.md`, `GEMINI.md`, `.agents/rules/*.md`, `.agents/skills/`, and `.agents/skills.json` override the global plugin baseline within that project; `install-product` remains optional for team-committed repo bindings.
- **Prevent duplicated roots:**
  - Do **not** keep duplicate B3 skills in `~/.gemini/config/skills/` or `~/.agents/skills/`, or a second plugin directory with `"name": "b3-ai-engineering"` under `~/.gemini/config/plugins/` (`verify` flags each with `COEXISTENCE_WARNING:`).
  - **Cursor coexistence:** Installing global Cursor (`~/.cursor/`) alongside the global Antigravity plugin (`~/.gemini/config/plugins/b3-ai-engineering/`) shares one canonical `B3_HOME` cleanly with zero cross-host warnings. In a shared per-product repo, use `install-product -HostName cursor` (avoid creating repo `.agents/skills`) and keep the global Antigravity plugin active.
- **Migration from pre-manifest plugin install:** Back up any changes to generated files, then run `install -Force` / `install --force` to adopt the legacy installation into `.b3-plugin-manifest` (or remove/move colliding files first). Plain `install`/`update` now refuses to overwrite untracked generated files. The legacy `uninstall` fallback remains separate from manifest-tracked uninstall.

## 3. Alternative local & product setup modes

### Working inside this B3 checkout

No `.agents/skills` junction is needed (and **do not** add `.agents/skills` alongside committed `.agents/skills.json`). Verify `.agents/skills.json`:

```powershell
.\adapters\sync-skills.ps1 -HostName antigravity -VerifyOnly
```

```bash
./adapters/sync-skills.sh --verify antigravity
```

### Optional product repository attach (`install-product`)

```powershell
.\adapters\install-product.ps1 -ProductRoot D:\path\to\your-product -HostName antigravity
```

```bash
./adapters/install-product.sh --product-root /path/to/your-product --host antigravity
```

## 4. Known limitations & honest verification boundary

- **UI lifecycle grants:** Antigravity stores user enable/disable state in `~/.gemini/config/config.json`. Enable, disable, or review the plugin in Antigravity UI (`[B3 AI Engineering](customization://b3-ai-engineering)`); installer scripts never hand-edit `config.json`.
- **Filesystem vs. runtime discovery:** Automated validation ([`../../scripts/validate-antigravity-global.ps1`](../../scripts/validate-antigravity-global.ps1)) proves file generation, Windows NTFS junction validity, raw SHA-256 parity across PowerShell and Git Bash, drift detection, conflict protection, coexistence warnings, and clean uninstall (`PASS`). Non-Windows POSIX (`macOS`/`Linux`) `.sh` symlink (`ln -s`) / `shasum` / `openssl` execution and live Antigravity IDE/CLI discovery of `skills/`, command skills, `rules/AGENTS.md`, and `agents/*.md` remain **`UNKNOWN / INCOMPLETE`** until observed on those environments.

## 5. Runtime smoke-test checklist (2 unrelated Antigravity projects)

Run this manual verification in two local repositories (`repo-a`, `repo-b`) that have **never** run `install-product`:
1. Confirm `.\adapters\install-global.ps1 verify -HostName antigravity` (or `./adapters/install-global.sh verify --host antigravity`) exits `0` with `check.{plugin,rules,skills,commands,agents,skills_json}=OK` and zero `COEXISTENCE_WARNING:` lines.
2. Open `[B3 AI Engineering](customization://b3-ai-engineering)` in Antigravity Customizations UI and verify the global plugin appears enabled with bundled rules, skills, and subagents.
3. **Skills discovery:** In `repo-a` and `repo-b`, ask a verification or debugging question and confirm matching B3 skills activate without local `.agents/skills` in the repo.
4. **Commands & workflows:** Trigger `/b3-plan` and `/b3-review` in both repos; confirm `B3_HOME` resolves via the global path in plugin `rules/AGENTS.md` without writing `.b3/home` or copying `skills/`.
5. **Rules precedence:** Add a temporary rule in `repo-a/AGENTS.md` or `repo-a/.agents/rules/` overriding a preference and confirm Antigravity honors the project rule over the global plugin baseline.
6. **Subagents:** Trigger an independent review (`b3-reviewer` or `b3-security-reviewer`) and verify read-only isolated findings return (or record `UNKNOWN / INCOMPLETE` / single-agent limitation if host subagent delegation is unavailable).
7. Run `git status` in both repos to confirm zero stray B3 modifications remain.

## References

- [`../README.md`](../README.md)
- [`../../scripts/validate-antigravity-global.ps1`](../../scripts/validate-antigravity-global.ps1)
- [`../../research/decisions/decision-011-product-repo-attach.md`](../../research/decisions/decision-011-product-repo-attach.md)
- [`../../research/decisions/decision-013-host-neutral-multi-host-layout.md`](../../research/decisions/decision-013-host-neutral-multi-host-layout.md)
- [`../../research/decisions/decision-017-global-cursor-integration.md`](../../research/decisions/decision-017-global-cursor-integration.md)
