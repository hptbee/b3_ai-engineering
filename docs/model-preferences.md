# Lightweight Markdown Model Preferences

B3 model preferences are an optional, human- and AI-readable convenience file. They require zero external dependencies (no Node.js, Python, or `jq`) and no custom parser.

- **Copy-ready template:** [`config/models.example.md`](../config/models.example.md)
- **Personal preferences (machine-wide):** `~/.b3/models.md` (or `B3_MODELS_PERSONAL` env var)
- **Project override (Git-ignored per repo):** `<project>/.b3/models.md`

## Customization

1. Copy [`config/models.example.md`](../config/models.example.md) to `~/.b3/models.md` (or `<project>/.b3/models.md`), or let [`adapters/install-product.{ps1,sh}`](../adapters/install-product.ps1) / [`adapters/sync-skills.{ps1,sh}`](../adapters/sync-skills.ps1) create `~/.b3/models.md` if missing.
2. Replace `auto` for any role you want to customize (for example, `planning`, `implementation`, `b3-reviewer`, `b3-fixer`, or specialist reviewers). Readable model names or host-recognized IDs are both fine.
3. Existing `~/.b3/models.md` files are never overwritten by B3 updates or installers. Set `B3_SKIP_MODEL_INIT=1` to skip auto-creating `~/.b3/models.md`.

## Precedence & On-Demand Loading

1. Explicit user selection in the host UI or CLI always wins.
2. `<project>/.b3/models.md` (when present) overrides machine-wide settings.
3. `~/.b3/models.md` (or `B3_MODELS_PERSONAL`).
4. Native platform default (`auto`).

To avoid always-on context bloat, `AGENTS.md` and `rules/*.md` do not load model preferences. Orchestrators load [`workflows/references/dispatch-naming.md`](../workflows/references/dispatch-naming.md) at dispatch and read `.b3/models.md` / `~/.b3/models.md` at most once per dispatch phase across `/b3-ship`, `/b3-review-loop`, planning/implementation, and review/fix dispatch. Missing, partial, or malformed preference files fall back to native model selection and never block work.

## Platform Behavior & Honest Limits

| Host | Supported Selection vs Advisory Behavior | Fallback |
| --- | --- | --- |
| **Cursor** | Active chat UI picker controls `main`; user-level `~/.cursor/agents/*.md` can configure subagent `model:` locally ([`adapters/cursor/review-loop-models.md`](../adapters/cursor/review-loop-models.md)). | Committed `agents/*.md` keep `model: inherit`; native/parent selection applies when `auto` or unsupported. |
| **Antigravity** | Respects host UI model selection and may pass a compatible runtime `Model` parameter during subagent delegation when supported. | Falls back transparently to Antigravity's native/inherited model. Never edits `~/.gemini` settings. |
| **Codex** | Respects CLI/session profile selection (`codex --model ...` when invoked by the user); B3 workflows never embed vendor IDs or modify `~/.codex/config.toml`. | Uses Codex's configured default model when `auto` or omitted. |
| **Claude Code** | Respects session selection and explicit `--model` CLI flags or user-level agent frontmatter; never edits `~/.claude/settings.json` or committed `agents/*.md`. | Falls back to Claude Code's native session/parent model (`inherit`). |

B3 never claims a model switch occurred unless the host runtime actually confirms or applies it.

## Upgrading from Earlier PR #21 JSON Config

Earlier PR #21 drafts used `~/.b3/models.local.json` or `<project>/.b3/models.local.json`. B3 does not delete or overwrite existing JSON files automatically:

1. Open your existing `~/.b3/models.local.json` (or `<project>/.b3/models.local.json`).
2. Copy any custom non-`auto` role entries into `~/.b3/models.md` (or `<project>/.b3/models.md`), starting from [`config/models.example.md`](../config/models.example.md).
3. Remove the old `.json` file manually once migrated if you no longer need it.
