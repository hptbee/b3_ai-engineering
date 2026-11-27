# Codex adapter

**Status:** implemented adapter; live runtime skill discovery in a fresh Codex session remains `UNKNOWN / INCOMPLETE` until observed and recorded (`research/validation/codex-host-v1.md`).

> **Native binary:** Obtain `b3` once via [`../../scripts/bootstrap-b3.ps1`](../../scripts/bootstrap-b3.ps1) / [`../../scripts/bootstrap-b3.sh`](../../scripts/bootstrap-b3.sh) (zero-Rust checksum-verified bootstrapper) or `cargo build --release`.

## This repo → Codex

| Core | Codex mapping |
| --- | --- |
| `AGENTS.md` | Primary operating file; merged chain subject to ~32 KiB default cap |
| `rules/*.md` | Referenced from `AGENTS.md` — do not duplicate prose |
| `skills/` | Exposed through gitignored flattened `.agents/skills/<name>` via `b3 sync --host codex` |
| `commands/` + `adapters/command-skills/` | Exposed as `$b3-ship`, `$b3-research-ship`, `$b3-plan`, `$b3-implement`, `$b3-debug`, `$b3-review`, `$b3-verify`, `$b3-review-loop`, `$b3-pr-resolve`, `$b3-pr-reply`, `$b3-pr-comment` in `.agents/skills/<name>` + prompt routing |
| `agents/*.md` | Role prompt source for delegated reviewer/fixer/security/architecture/performance work |

Review-loop model slots stay host-configured (`review-loop/models.md`). Do not hard-code vendor model names in skill bodies.

## Setup

### Inside this B3 checkout

Create the local gitignored flattened `.agents/skills/<name>` index (core `skills/` + `adapters/command-skills/`):

```bash
b3 sync --host codex
b3 sync --host codex --verify-only
```

> **Coexistence notes:**
> - `b3 sync --host codex` refuses to run while `.cursor/skills` exists (Cursor cross-loads `.agents/skills` and duplicates skills) unless `--force` is passed.
> - If `.agents/skills.json` is generated for Antigravity (`b3 sync --host antigravity`) while `.agents/skills/` exists, Antigravity may read both.

### Separate product repository

```bash
b3 install product --product-root /path/to/product --host codex
```

Writes `.b3/home`, thin `AGENTS.md` (when missing), `.b3/ship/`, `.b3/research-ship/`, `.b3/pr-feedback/`, `.b3/models.md`, and `.agents/skills` in `.gitignore`, and a gitignored flattened `.agents/skills/<name>` index (one junction/symlink per B3 skill plus command skills such as `b3-ship`).

## Command and role routing

- `b3-ship` on Codex is `$b3-ship` (`adapters/command-skills/b3-ship/SKILL.md`), installed as `.agents/skills/b3-ship`. It routes directly in 1 hop to `{B3_HOME}/workflows/ship.md` without an intermediate `commands/b3-ship.md` hop or duplicating the procedure.
- For review-loop delegation, pass `agents/b3-reviewer.md`, `b3-fixer.md`, `b3-security-reviewer.md`, `b3-architecture-reviewer.md`, or `b3-performance-reviewer.md` to an isolated delegated agent when available. Parent remains orchestrator.
- **Host-native parallel/subagent fallback:** When Codex runs without isolated parallel subagents, degrade cleanly to `SEQUENTIAL` (`no_host_isolation` / `sequential_host_fallback` per [`../../workflows/references/dispatch-naming.md`](../../workflows/references/dispatch-naming.md)) and record `SINGLE_AGENT_LIMIT` / `UNKNOWN` where independent review is required.

## Thin by design

CLI flags and Codex-only config stay here. Core rules and skill procedures remain host-agnostic.

## References

- [`../README.md`](../README.md)
- [`../../workflows/references/dispatch-naming.md`](../../workflows/references/dispatch-naming.md)
- `research/sources/openai-codex-customization.md`
- `research/decisions/decision-013-host-neutral-multi-host-layout.md`
