# User-Customizable Model Configuration

B3 separates **shared framework defaults** from **developer-specific model preferences** using plain JSON and zero external dependencies.

- **Shared defaults (version-controlled):** [`config/models.default.json`](../config/models.default.json) (all roles set to `"auto"`)
- **Copy-ready example:** [`config/models.example.json`](../config/models.example.json)
- **Personal override (Git-ignored, machine-wide):** `~/.b3/models.local.json` (or `B3_MODELS_PERSONAL` env var)
- **Project override (Git-ignored per repo):** `<repo>/.b3/models.local.json`

Existing workflows, skills, commands, and committed `agents/*.md` files (`model: inherit`) never embed personal or hardcoded vendor model IDs. Missing configuration files fall back cleanly to native platform selection.

## Quick Start

1. Run [`adapters/sync-skills.{ps1,sh}`](../adapters/sync-skills.ps1) or [`adapters/install-product.{ps1,sh}`](../adapters/install-product.ps1) (automatically seeds `~/.b3/models.local.json` from `config/models.default.json` if missing, without overwriting existing settings), or copy `config/models.example.json` to `~/.b3/models.local.json`.
2. Edit only the roles you want to customize (omitted roles inherit lower layers):

```json
{
  "version": 1,
  "models": {
    "planning": "your-preferred-reasoning-model",
    "b3-reviewer": "your-preferred-reviewer-model",
    "b3-fixer": "auto"
  }
}
```

3. Audit your effective resolved models:

```powershell
# Windows PowerShell
.\scripts\b3-guard.ps1 resolve-models
.\scripts\b3-guard.ps1 resolve-models -Role b3-reviewer -Json
```

```bash
# macOS / Linux / Git Bash
./scripts/b3-guard.sh resolve-models
./scripts/b3-guard.sh resolve-models --role b3-reviewer --json
```

## Supported Roles

| Role | Covers |
| --- | --- |
| `main` | Primary interactive orchestrator / conversation session |
| `planning` | `/b3-plan` and Plan / Scope phases |
| `implementation` | Feature / task coding and refactoring builds |
| `debugging` | `/b3-debug` root-cause investigation and bug-class sweeps |
| `b3-reviewer` | [`agents/b3-reviewer.md`](../agents/b3-reviewer.md) (`readonly: true`) |
| `b3-fixer` | [`agents/b3-fixer.md`](../agents/b3-fixer.md) (`readonly: false`) |
| `b3-security-reviewer` | [`agents/b3-security-reviewer.md`](../agents/b3-security-reviewer.md) (`readonly: true`) |
| `b3-architecture-reviewer` | [`agents/b3-architecture-reviewer.md`](../agents/b3-architecture-reviewer.md) (`readonly: true`) |
| `b3-performance-reviewer` | [`agents/b3-performance-reviewer.md`](../agents/b3-performance-reviewer.md) (`readonly: true`) |

Unrecognized keys inside `models` emit `UNKNOWN_ROLE_WARNING:` without failing execution.

## Resolution Precedence & `"auto"`

1. **Explicit user selection** (`-ExplicitModel` / `--explicit-model` or active chat UI picker) → `source=explicit`
2. **Project personal override** (`<repo>/.b3/models.local.json`, ignored via `.gitignore`) → `source=project`
3. **Developer personal override** (`~/.b3/models.local.json` or `B3_MODELS_PERSONAL`) → `source=personal`
4. **Shared defaults** (`{B3_HOME}/config/models.default.json`) → `source=default`
5. **Native platform fallback** (`"auto"`) → `source=platform_default`

- **`"auto"`** means delegate selection to the host platform (`effective=platform_default`). Setting `"auto"` in a higher layer overrides a concrete model set in a lower layer.
- **Invalid config fails closed cleanly:** malformed JSON, wrong `version` (must be integer `1`), missing `models`, unsupported top-level keys (only `version`, `models`, `_comment`), or empty/non-string model values exit `1` with `CONFIG_ERROR:`.

## Platform Support & Honest Limits

JSON resolution never writes unsolicited changes to IDE settings, CLI configs, or committed agent Markdown:

| Host | Actual model selection vs preference guidance | Fallback when unsupported |
| --- | --- | --- |
| **Cursor** | Supports explicit UI picker for `main` chat, and `model: <id>` frontmatter on local/user subagent files ([`adapters/cursor/review-loop-models.md`](../adapters/cursor/review-loop-models.md)). | Keeps `model: inherit` on committed `agents/*.md`; falls back to parent/Cursor picker when `"auto"` or subagent isolation is unavailable. |
| **Antigravity** | Respects host UI model selection and any supported runtime subagent `Model` parameter during delegation; never auto-rewrites `~/.gemini/config/config.json`. | Falls back transparently to Antigravity's native selected model (`"auto"`). |
| **Codex** | Can invoke Codex CLI explicitly with resolved preferences (`codex --model "$(./scripts/b3-guard.sh resolve-models --role main \| awk -F'[= ]+' '/^role=main/{print $4}')"` when non-`auto`); never modifies `~/.codex/config.toml`. | Uses Codex's configured default profile/model when `"auto"` or omitted. |

B3 never claims a requested model ran when the host platform controls selection externally.

## Updates & Resetting

- **Surviving updates:** Because personal preferences live in Git-ignored `~/.b3/models.local.json` (and optional `<repo>/.b3/models.local.json`), `git pull`, `sync-skills`, and `install-product` never overwrite them.
- **Reset to defaults:** Delete `~/.b3/models.local.json` (or `<repo>/.b3/models.local.json`), or copy `config/models.default.json` back over it.
