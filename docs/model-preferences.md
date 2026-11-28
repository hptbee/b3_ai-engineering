# Model Preferences & Legacy `models.md` Bridge

> [!NOTE]
> **Canonical configuration guide:** Unified typed TOML configuration (`~/.b3/config.toml`, `<project>/.b3/config.toml`, `.b3/policy.toml`, `b3 config` CLI, adaptive model routing, and all schema keys) now lives in [`docs/configuration.md`](configuration.md). This page remains as a stable link target and migration bridge from legacy `models.md`.

B3 advisory preferences are user- and repo-local configuration files separated strictly from trunk governance (`.b3/policy.toml`).

- **Canonical template:** [`config/config.example.toml`](../config/config.example.toml) *(supersedes the retired legacy Markdown model template)*
- **Personal preferences (machine-wide):** `~/.b3/config.toml` (or `B3_CONFIG_PERSONAL` env var; legacy `~/.b3/models.md` / `B3_MODELS_PERSONAL`)
- **Project override (Git-ignored per repo):** `<project>/.b3/config.toml` *(legacy `<project>/.b3/models.md`)*

## Customization & Migration

1. Run `b3 config init` (or copy [`config/config.example.toml`](../config/config.example.toml)) to create `~/.b3/config.toml`, or `b3 config init --scope project` for `<project>/.b3/config.toml`. `b3 install global`, `b3 install product`, and `b3 sync` also seed a missing `~/.b3/config.toml` unless `B3_SKIP_CONFIG_INIT=1` (legacy `B3_SKIP_MODEL_INIT=1`) is set or legacy `~/.b3/models.md` already exists.
2. If you already have `~/.b3/models.md` or `<project>/.b3/models.md`, run `b3 config migrate` (supports `--dry-run`) to convert roles and `planning` settings into `config.toml` non-destructively without overwriting existing files.
3. Configure `[models.tiers]` (`economy`, `balanced`, `advanced`, or `"auto"`) and `[models.roles]` (`1–3` ordered entries per role). Existing `~/.b3/config.toml` files are never overwritten by B3 updates or installers.

**Global install behavior:** `b3 install global` supports Cursor, Antigravity, or both. `~/.b3/config.toml` is created once per successful `install`/`update`, respects `--user-home` and the `B3_CONFIG_PERSONAL` explicit path override, defers when legacy `models.md` is present, and is never overwritten. `B3_SKIP_CONFIG_INIT=1` (and legacy `B3_SKIP_MODEL_INIT=1`) disables initialization. `--dry-run` only previews; `verify` / `uninstall` neither create nor remove preferences. `b3 install cursor` and `b3 install antigravity` do not seed it: use `b3 install global`, `b3 config init`, or copy the example manually.

## Precedence & On-Demand Loading

1. Explicit invocation / CLI overrides (`--override KEY=VALUE` or prompt override) always win.
2. Supported environment variables (`B3_MODEL_ROUTING`, `B3_MAX_CONCURRENCY`, `B3_EXECUTION_MODE`, `B3_CLARIFICATION_GATE`, `B3_UNDERSTANDING_THRESHOLD`, `B3_REPORTING_VERBOSITY`).
3. `<project>/.b3/config.toml` (when present) overrides machine-wide settings.
4. `~/.b3/config.toml` (or `B3_CONFIG_PERSONAL`).
5. Built-in defaults (`auto` tiers, `routing = "adaptive"`, `clarification_gate = true`, `understanding_threshold = 96`).

To avoid always-on context bloat, `AGENTS.md` and `rules/*.md` do not load configuration files. Orchestrators resolve preferences once per invocation via `b3 config` (and [`workflows/references/dispatch-naming.md`](../workflows/references/dispatch-naming.md) at dispatch) across `/b3-ship`, `/b3-research-ship`, `/b3-review-loop`, planning/implementation/debugging, and review/fix dispatch. A 1-task `XS` + `inline` build runs inline on `main` when `implementation` is unset/`auto` or matches `main`, and dispatches `b3-impl-t00N` (or standalone `/b3-implement` subagent) when `implementation` differs from `main` or on multi-task / `>= S` / `notes` / `detailed` work. Missing, partial, or malformed preference files fall back per field to the next valid layer and never block work.

## Platform Behavior & Honest Limits

See the full capability matrix in [`docs/configuration.md#5-host-capability-matrix--identity-honesty`](configuration.md#5-host-capability-matrix--identity-honesty):

- **Cursor:** Active UI picker controls `main`; user-level `~/.cursor/agents/*.md` can configure subagent `model:` locally ([`adapters/cursor/README.md`](../adapters/cursor/README.md)). Committed `agents/*.md` keep `model: inherit`. Runtime `identity_confirm` is `false`.
- **Cursor CLI:** Supports `main` selection and `identity_confirm`; subagents inherit the session model (`subagent_select = false`).
- **Codex:** Respects CLI/session profile selection (`codex --model ...`) and supports `subagent_select`, `per_task_routing`, and `identity_confirm`; never edits `~/.codex/config.toml`.
- **Claude Code:** Respects session selection, explicit `--model`, and user-level frontmatter (`subagent_select`, `per_task_routing`, `identity_confirm`); never edits `~/.claude/settings.json` or committed `agents/*.md`.
- **Antigravity:** Respects host UI model selection and passes compatible runtime `Model` parameters when supported (`subagent_select`, `per_task_routing`), with `identity_confirm = false`; never edits `~/.gemini` settings.

B3 never claims a model switch occurred unless the host runtime actually confirms or applies it (reporting `INHERITED` or `UNKNOWN` otherwise).

## `[planning]` Clarification Gate Settings

The same configuration files (`~/.b3/config.toml` / `B3_CONFIG_PERSONAL` and `<project>/.b3/config.toml`) host `[planning]` settings for [`workflows/references/clarification-gate.md`](../workflows/references/clarification-gate.md):

- **Field-level precedence:** `invocation override > env vars > <project>/.b3/config.toml > ~/.b3/config.toml (B3_CONFIG_PERSONAL) > built-in defaults (clarification_gate = true, understanding_threshold = 96)`.
- **Resolve once & per-field fallback:** Parent resolves effective `[planning]` values once per invocation (workers do not re-read `config.toml`). Missing, partial, or malformed fields/files fall back **per field to the next valid layer** before built-in defaults (`true`, `96`), never discarding valid personal values when a project override is partial or malformed, and never blocking across hosts.
- Disabling `clarification_gate` only relaxes routine ambiguity prompts; it **never** bypasses security boundaries, required user authorization, research governance, protected paths, destructive safeguards, or merge authorization.

### Field-Level Merge Example (TOML)

If `~/.b3/config.toml` sets:

```toml
[planning]
clarification_gate = true
understanding_threshold = 90
```

and `<project>/.b3/config.toml` sets only:

```toml
[planning]
clarification_gate = false
```

the effective configuration resolved by Parent for that invocation is `clarification_gate = false` and `understanding_threshold = 90` (if `<project>/.b3/config.toml` instead had an invalid threshold such as `understanding_threshold = "abc"`, that invalid field falls back to the personal `90`, or to `96` if personal omitted it).

### Enabled vs Disabled (TOML)

```toml
# Enabled (default behavior)
[planning]
clarification_gate = true
understanding_threshold = 96
```

```toml
# Disabled (document reversible assumptions instead of routine prompts)
[planning]
clarification_gate = false
```

### Project Override (`<project>/.b3/config.toml`)

```toml
[planning]
clarification_gate = true
understanding_threshold = 98
```

### Per-Invocation Override (CLI or Prompt Syntax)

```bash
b3 config show --override planning.clarification_gate=false
```

```text
/b3-ship clarification_gate: false -- implement the pagination endpoint using repo conventions
```

(Or raise/lower threshold for one run via `--override planning.understanding_threshold=90` or prompt override `understanding_threshold: 90`.)

## Upgrading from Earlier Legacy Formats

- **From `models.md` (`~/.b3/models.md` or `<project>/.b3/models.md`):** Run `b3 config migrate --scope personal` or `b3 config migrate --scope project` (or `--scope all`). Legacy files are preserved and never overwritten.
- **From earlier PR #21 `models.local.json`:** Move any custom non-`auto` role entries into `~/.b3/config.toml` (or `<project>/.b3/config.toml`), starting from [`config/config.example.toml`](../config/config.example.toml), then remove the `.json` file manually.
