# B3 Model Preferences

Optional, advisory model preferences for B3 workflows. Copy to `~/.b3/models.md` (machine-wide) or `<project>/.b3/models.md` (repo-local override). Missing, partial, or malformed files never block execution.

| Role | Preferred Model | Notes |
| --- | --- | --- |
| `main` | auto | Primary orchestrator / interactive session |
| `planning` | auto | `/b3-plan` and Plan / Scope phases |
| `implementation` | auto | Feature / task builds (`/b3-implement`, `/b3-ship`) |
| `debugging` | auto | `/b3-debug` root-cause investigation |
| `b3-reviewer` | auto | Independent code review (`agents/b3-reviewer.md`) |
| `b3-fixer` | auto | Focused fix & verification (`agents/b3-fixer.md`) |
| `b3-security-reviewer` | auto | Security review (`agents/b3-security-reviewer.md`) |
| `b3-architecture-reviewer` | auto | Architecture review (`agents/b3-architecture-reviewer.md`) |
| `b3-performance-reviewer` | auto | Performance review (`agents/b3-performance-reviewer.md`) |

## Rules

- `auto` means inherit the platform-selected model.
- Explicit user selection in the active host UI or CLI always takes precedence.
- Precedence: explicit user selection > `<project>/.b3/models.md` > `~/.b3/models.md` (or `B3_MODELS_PERSONAL`) > native `auto`.
- Readable model names or host-recognized IDs are both fine; B3 enforces no model registry or validation.
- Use a preferred model only when the active host exposes a supported selection mechanism; otherwise inherit the native model.
- Never block workflows, edit IDE settings, or mutate committed `agents/*.md` because of model preferences.

## Hook Preferences

Optional host-native guard hook preferences. Missing, partial, or malformed sections fall back to defaults (`enabled: true`, `mode: enforce`) with warnings.

```yaml
hooks:
  enabled: true
  mode: enforce
```

- Modes: `enforce` (block denied operations), `audit` (emit advisory warnings without blocking), `off` (no-op hook pass-through).
- Precedence: CLI / env `B3_HOOK_MODE` > `<project>/.b3/models.md` > `~/.b3/models.md` (or `B3_MODELS_PERSONAL`) > built-in defaults (`enabled: true`, `mode: enforce`).
- Hook installation is opt-in; upgrades and `b3 sync` never silently install blocking host hooks.
- Hook `audit` or `off` settings do not disable or bypass mandatory workflow Guards run inside B3 workflows or `b3 guard`.
