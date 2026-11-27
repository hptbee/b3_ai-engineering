# Cursor adapter

B3 keeps canonical rules, skills, commands, and agents in host-neutral root directories (`rules/`, `skills/`, `commands/`, `agents/`). Cursor can consume that single source of truth **globally (once per machine under `~/.cursor/`)** without touching unrelated repos, **per-repo via `b3 install product`**, or inside this B3 checkout via `b3 sync`.

> **Native binary:** Obtain `b3` once via [`../../scripts/bootstrap-b3.ps1`](../../scripts/bootstrap-b3.ps1) / [`../../scripts/bootstrap-b3.sh`](../../scripts/bootstrap-b3.sh) (zero-Rust checksum-verified bootstrapper) or `cargo build --release`.

## 1. Global installation (recommended, one-time per machine)

Installs under `~/.cursor/` via `b3 install cursor` (idempotent, dry-run safe, manifest-tracked `.b3-global-manifest`):
- **Skills (`~/.cursor/skills/<skill-name>`):** 1-level flattened junctions/symlinks to canonical `skills/*` (supports both Cursor IDE and Cursor CLI; excludes `adapters/command-skills/` to avoid duplicate `/` entries).
- **Commands (`~/.cursor/commands/b3-*.md`):** 14 thin generated entrypoints (`/b3-plan`, `/b3-implement`, `/b3-debug`, `/b3-research`, `/b3-audit`, `/b3-review`, `/b3-refactor`, `/b3-verify`, `/b3-review-loop`, `/b3-ship`, `/b3-research-ship`, `/b3-pr-resolve`, `/b3-pr-reply`, `/b3-pr-comment`) resolving `B3_HOME` globally via `~/.cursor/b3-home`.
- **Subagents (`~/.cursor/agents/b3-*.md`):** 5 generated role definitions (`b3-reviewer`, `b3-fixer`, `b3-security-reviewer`, `b3-architecture-reviewer`, `b3-performance-reviewer`) keeping `model: inherit` (no vendor model IDs).
- **Global Rules fallback (`~/.cursor/b3-user-rules.txt`):** compact plain-text baseline (`<= 1,200 B`) for **Cursor Settings > Rules > User Rules** (manual paste required — Cursor has no documented `~/.cursor/rules/*.mdc` directory).

### One-command CLI (`install`, `verify`, `update`, `uninstall`)

```bash
b3 install cursor
b3 install cursor verify
b3 install cursor update
b3 install cursor uninstall
```

To manage Cursor together with Antigravity from one shared canonical `B3_HOME`, use the unified dispatcher:

```bash
b3 install global --action install --host cursor
b3 install global --action install --host all
b3 install global --action verify --host all
```

Supports `--cursor-home <dir>`, `--plugin-root <dir>` / `--antigravity-plugin-root <dir>`, `--b3-home <dir>`, and `--user-home <dir>`. See [`../antigravity/README.md`](../antigravity/README.md) for Antigravity checks.

**Optional model preferences:** `b3 install global` initializes `~/.b3/models.md` after a successful install/update without overwriting existing preferences. If you use `b3 install cursor` directly, copy [`../../config/models.example.md`](../../config/models.example.md) to `~/.b3/models.md` yourself. Preferences are advisory and loaded only on relevant dispatch; see [`../../docs/model-preferences.md`](../../docs/model-preferences.md).

- Pass `--dry-run` to preview changes without touching disk.
- Pass `--force` to replace conflicting same-named unmanaged files or migrate a legacy `~/.cursor/skills/b3-ai-engineering` link. Unrelated user files (`~/.cursor/skills/my-*`, custom commands/agents) are never removed or modified.

### Arbitrary-project usage examples

In any Git repo that has never run `b3 install product`:
- Type `/b3-plan`, `/b3-research`, `/b3-audit`, `/b3-review`, `/b3-refactor`, `/b3-verify`, `/b3-debug`, `/b3-implement`, `/b3-review-loop`, `/b3-ship`, `/b3-research-ship`, `/b3-pr-resolve`, `/b3-pr-reply`, or `/b3-pr-comment`.
- Let B3 resolve `B3_HOME` in order: `B3_HOME` env -> project `.b3/home` -> `~/.cursor/b3-home`.
- **Host-native parallel/subagent fallback:** When Cursor subagent isolation or parallel dispatch is unavailable, workflows degrade cleanly to `SEQUENTIAL` (`no_host_isolation` / `sequential_host_fallback` per [`../../workflows/references/dispatch-naming.md`](../../workflows/references/dispatch-naming.md)) and record `SINGLE_AGENT_LIMIT` / `UNKNOWN` where independent review is required.

## 2. Global vs. project-specific overrides

- **Project overrides win on project requirements:** repo `AGENTS.md`, `.cursor/rules/*.mdc`, `.cursor/skills/`, `.cursor/commands/`, and `.cursor/agents/` extend or override global B3 defaults.
- **`b3 install product` is optional:** only needed when a team wants repo-committed `.b3/home` and `.cursor/commands/*.md` shared via Git.
- **Migration:**
  - From legacy `~/.cursor/skills/b3-ai-engineering`: run `b3 install cursor --force`.
  - From per-project `b3 install product`: project `.cursor/commands/b3-*.md` and `.b3/home` remain compatible alongside global `~/.cursor/`.

## 3. Alternative local/product modes

| Mode | Command | When |
| --- | --- | --- |
| Inside this B3 checkout | `b3 sync --host cursor` | Generates gitignored `.cursor/{skills,commands,agents}` links + `.cursor/rules/*.mdc` wrappers (`alwaysApply: true` for hard global rules, `false` for `simplest-correct`) without overwriting user `.mdc` files |
| Optional per-project attach | `b3 install product --product-root <dir> --host cursor` | Team-committed repo pointer |

Do **not** also activate `.agents/skills` or `.claude/skills` in the same checkout — Cursor cross-loads those roots (`b3 install` / `b3 sync` emits `COEXISTENCE_WARNING:` if overlapping `~/.agents/skills/` or `~/.claude/skills/` exist).

## 4. Known limitations & honest status

- **Global User Rules UI:** Cursor stores global User Rules in Cursor Settings (plain text); automatic script injection is not supported (`b3-user-rules.txt` must be pasted once manually).
- **Cursor CLI nesting:** Flattened 1-level skill links ensure compatibility with both Cursor IDE and CLI.
- **Filesystem vs. runtime verification:** Automated native Rust tests verify links, SHA-256 hashes, conflicts, updates, paths with spaces, and clean uninstall (`PASS`), **not** live Cursor UI/CLI discovery (`UNKNOWN / INCOMPLETE` until exercised in Cursor).
- **Model overrides:** Orchestrator stays the parent session ([`../../review-loop/models.md`](../../review-loop/models.md)), and committed `agents/*.md` keep `model: inherit`. Prefer `~/.b3/models.md` or `<project>/.b3/models.md` ([`../../docs/model-preferences.md`](../../docs/model-preferences.md)) for advisory preferences; for Cursor-native overrides, set `model:` (using IDs accepted by your Cursor build per [Cursor subagents](https://cursor.com/docs/context/subagents)) only in user-level `~/.cursor/agents/*.md` or local `.cursor/agents/*.md` (never commit vendor model IDs). After changing `model:`, start a new Agent chat and run `/b3-review-loop` to verify the parent dispatches isolated agents instead of running in one turn (subagent auto-delegation remains **NOT VERIFIED** as a product-wide claim per [`../../research/validation/cursor-host-v3.md`](../../research/validation/cursor-host-v3.md)).

## 5. Runtime smoke-test checklist (2 unrelated Cursor projects)

Run this manual check on two local Git repos (`repo-a`, `repo-b`) that have **never** run `b3 install product`:
1. Paste `~/.cursor/b3-user-rules.txt` into **Cursor Settings > Rules > User Rules**.
2. **Commands (`/b3-plan`, `/b3-verify`):** in `repo-a` and `repo-b`, confirm `/` shows all 14 B3 commands (`/b3-plan`, `/b3-implement`, `/b3-debug`, `/b3-research`, `/b3-audit`, `/b3-review`, `/b3-refactor`, `/b3-verify`, `/b3-review-loop`, `/b3-ship`, `/b3-research-ship`, `/b3-pr-resolve`, `/b3-pr-reply`, `/b3-pr-comment`), and resolves `B3_HOME` via `~/.cursor/b3-home` without creating `.b3/home` in the repo.
3. **Skills:** verify skill triggers (e.g., review/debugging) load from `~/.cursor/skills/<name>/SKILL.md` cleanly.
4. **Rules precedence:** add a temporary project rule in `repo-a/.cursor/rules/` or `repo-a/AGENTS.md` and confirm Cursor honors the project rule over personal defaults.
5. **Subagents:** invoke an independent review (`b3-reviewer` / `b3-security-reviewer`) and confirm isolated read-only findings return cleanly (or record `UNKNOWN / INCOMPLETE` / `SINGLE_AGENT_LIMIT` per [`../../workflows/references/dispatch-naming.md`](../../workflows/references/dispatch-naming.md) if the host cannot isolate subagents).
6. Confirm `git status` in both repos has zero unexpected B3 files when finished.

## References

- [`../README.md`](../README.md)
- [`../../workflows/references/dispatch-naming.md`](../../workflows/references/dispatch-naming.md)
- [`../../research/sources/cursor-docs-2026-09.md`](../../research/sources/cursor-docs-2026-09.md)
- [`../../research/decisions/decision-013-host-neutral-multi-host-layout.md`](../../research/decisions/decision-013-host-neutral-multi-host-layout.md)
- [`../../research/decisions/decision-017-global-cursor-integration.md`](../../research/decisions/decision-017-global-cursor-integration.md)
