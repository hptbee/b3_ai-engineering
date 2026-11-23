# Subagent dispatch naming (load only at spawn)

This is an on-demand contract for B3 orchestrators, **not** a global rule. Read once only when dispatching; do not copy it into each subagent brief.

- **Canonical roles:** Keep `agents/b3-*.md` filename stems and YAML `name:` stable (for example `b3-reviewer`, `b3-fixer`, `b3-security-reviewer`, `b3-architecture-reviewer`, `b3-performance-reviewer`).
- **Logical aliases:** Prefer `b3-impl-<task-id>` (e.g. `b3-impl-t002`) for implementation and `b3-research-<slug>` for research. Use lowercase ASCII kebab-case and a stable, unique task key; shorten long slugs deterministically if the host imposes a name limit, without collisions.
- **Host fallback:** Request the logical alias as a spawn/display name **only if the host API supports custom names**. Never pass unsupported `Role`/display fields or block dispatch because of naming. A host-generated name is acceptable.
- **Resume:** Keep the logical alias separate from the **host-returned agent ID**, when available. Store that ID in run state and resume by ID, not by alias. If there is no resumable ID, use a fresh agent (or record the existing single-agent independence limitation).
- **Scope:** Apply this convention to B3 subagent identifiers, not ordinary prose, application runtime workers, legacy `.b3/autodev/` checkpoints, or historical decision records. Runtime behavior and reviewer independence take priority over cosmetic naming.
## Model preference resolution

- Before dispatching workflow roles (`planning`, `implementation`, `debugging`, `b3-reviewer`, `b3-fixer`, `b3-security-reviewer`, `b3-architecture-reviewer`, `b3-performance-reviewer`), run `scripts/b3-guard.{ps1,sh} resolve-models` (once for all roles, or with `-Role`/`--role <role>`).
- When resolved `effective != platform_default` (non-`"auto"`), pass that model **only** if the active host exposes a runtime dispatch model parameter (for example Codex CLI `--model`, Claude Code `--model` / local agent `model:`, or Antigravity subagent `Model` matching a supported enum).
- When `effective == platform_default` (`"auto"`), or when the host controls model selection externally (such as Cursor interactive chat picker or canonical `agents/*.md` with `model: inherit`), treat JSON output as **preference-only** and keep native/parent selection — never fake switching or auto-edit IDE/CLI configs or committed `agents/*.md`.
- Missing config files fall back cleanly to `"auto"`; `CONFIG_ERROR:` (`exit 1`) surfaces broken config files instead of silently ignoring overrides.
