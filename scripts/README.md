# Scripts

Repository tooling, deterministic `/autodev` guard helpers, context-budget measurement, and validation suites. These scripts support agent workflows without replacing the active session as orchestrator (`research/decisions/decision-010-autonomous-development.md`).

## Tooling inventory

| Script | Purpose | Usage |
| --- | --- | --- |
| [`autodev-guard.ps1`](autodev-guard.ps1) / [`autodev-guard.sh`](autodev-guard.sh) | Deterministic `/autodev` & `/review-loop` helpers (`fingerprint`, `check-freshness`, `precommit`, `snapshot`, `diff-scope`) | `.\scripts\autodev-guard.ps1 <cmd> ...` / `./scripts/autodev-guard.sh <cmd> ...` |
| [`measure-context.ps1`](measure-context.ps1) / [`measure-context.sh`](measure-context.sh) | Measure always-on, `/autodev`, and `/review-loop` static context bytes/tokens; `--strict` / `-Strict` exits 1 if any soft cap is exceeded | `.\scripts\measure-context.ps1 -Strict` / `./scripts/measure-context.sh --strict` |
| [`validate-autodev-behavior.ps1`](validate-autodev-behavior.ps1) | End-to-end sandbox behavioral checks for 4-host `sync-skills`, `install-product`, Antigravity plugin, workflow recipes, `autodev-guard`, and strict context budget | `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\validate-autodev-behavior.ps1` |
| [`smoke-autodev-product.ps1`](smoke-autodev-product.ps1) | Isolated Git product-repo smoke test (attach pointer, task commits, interrupt/resume ancestry, residue fix, `autodev-guard`) | `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\smoke-autodev-product.ps1` |
| [`validate-evals.sh`](validate-evals.sh) | Verify required YAML keys (including `evals/agents/` `expected_bucket`) and confirm every `artifact:` path exists on disk | `./scripts/validate-evals.sh` |

## `autodev-guard` subcommands

| Subcommand | Exit codes | What it checks |
| --- | --- | --- |
| `fingerprint` | `0` ok, `1` bad args | Emits canonical `depends_on=<sorted ids or []>\|scope=<trimmed>\|acceptance_criteria=<; joined>` |
| `check-freshness` | `0` `FRESH`, `2` `STALE`, `1` error | Verifies `HEAD` descends from `task_base`, committed `watched_paths` untouched, and uncommitted `read_only_deps` untouched |
| `precommit` | `0` `PRECOMMIT_OK`, `1` fail | Confirms non-empty staged diff, zero `.b3/autodev/` staged, and every staged path is in `AllowedPaths` |
| `snapshot` | `0` SHA, `1` error | Runs `git stash create` (fallback `HEAD`) without modifying working tree or stash list |
| `diff-scope` | `0` summary, `2` `EMPTY_DIFF`, `1` error | Excludes `.b3/autodev/`, `IgnoreDirtyPaths`, and lockfile/generated noise; outputs `size_class`, `files`, `lines`, `review_files`, `noise_files` |

## Context budget soft caps (`measure-context`)

- `AGENTS.md` ≤ `3,600 B`
- `workflows/autonomous-development.md` ≤ `10,000 B`
- `review-loop/strategy.md` ≤ `6,000 B`
- Each `SKILL.md` file ≤ `4,000 B` and YAML frontmatter ≤ `280 B`
