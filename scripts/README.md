# Scripts

Repository tooling, deterministic `/autodev` & `/review-loop` guard helpers, context-budget measurement, and validation suites (`research/decisions/decision-010-autonomous-development.md`).

## Tooling inventory

| Script | Purpose | Usage |
| --- | --- | --- |
| [`autodev-guard.ps1`](autodev-guard.ps1) / [`autodev-guard.sh`](autodev-guard.sh) | Deterministic `/autodev` & `/review-loop` helpers | `.\scripts\autodev-guard.ps1 <cmd> ...` / `./scripts/autodev-guard.sh <cmd> ...` |
| [`measure-context.ps1`](measure-context.ps1) / [`measure-context.sh`](measure-context.sh) | Measure always-on, `/autodev`, `/review-loop`, and subagent static context bytes/tokens (`-Strict` / `--strict` exits 1 on cap violation) | `.\scripts\measure-context.ps1 -Strict` / `./scripts/measure-context.sh --strict` |
| [`validate-autodev-behavior.ps1`](validate-autodev-behavior.ps1) | End-to-end sandbox behavioral checks for 4-host `sync-skills`, `install-product`, Antigravity plugin, workflow recipes, `autodev-guard`, and strict context budget | `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\validate-autodev-behavior.ps1` |
| [`smoke-autodev-product.ps1`](smoke-autodev-product.ps1) | Isolated Git product-repo smoke test (attach pointer, run-scoped checkpoints, task commits, interrupt/resume ancestry, residue fix) | `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\smoke-autodev-product.ps1` |
| [`validate-evals.sh`](validate-evals.sh) | Verify required YAML keys and confirm every `artifact:` path exists on disk | `./scripts/validate-evals.sh` |

## `autodev-guard` subcommands

| Subcommand | Exit codes | What it does |
| --- | --- | --- |
| `fingerprint` | `0` ok, `1` bad args | Emits canonical `depends_on=<sorted ids or []>\|scope=<trimmed>\|acceptance_criteria=<; joined>` |
| `check-freshness` | `0` `FRESH`, `2` `STALE`, `1` error | Verifies `HEAD` descends from `task_base`, committed `watched_paths` untouched, and uncommitted `read_only_deps` untouched |
| `precommit` | `0` `PRECOMMIT_OK`, `1` fail | Confirms non-empty staged diff, zero `.b3/autodev/` staged, and every staged path is in `AllowedPaths` |
| `snapshot` | `0` SHA, `1` error | Runs `git stash create` (fallback `HEAD`) without modifying working tree or stash list |
| `diff-scope` | `0` summary, `2` `EMPTY_DIFF`, `1` error | Rename-safe (`--no-renames`), excludes `.b3/autodev/`, `IgnoreDirtyPaths`, and lockfile/generated noise; `-BaseSha`/`--base-sha` defaults to `auto` (dirty WT -> `HEAD`; clean WT on feature branch -> merge-base with `origin/main` or `main`); optional `-TargetRef`/`--target-ref` (e.g. `FETCH_HEAD`) diffs a commit/ref without touching WT/untracked; outputs `size_class` (`NOISE_ONLY`\|`SMALL`\|`MEDIUM`\|`LARGE`\|`VERY_LARGE`), `files`, `lines`, `review_files`, `noise_files`, plus `delta_files` when `-PrevSha`/`--prev-sha` is supplied |
| `mechanical-check` | `0` `MECHANICAL_OK`, `2` `MECHANICAL_FINDINGS`, `1` error | Deterministic pre-review audit (`0 LLM tokens`): `-BaseSha`/`--base-sha` defaults to `auto` (optional `-TargetRef`/`--target-ref` diffs and checks `Obsoletes` in that ref); checks `scope_creep` against `AllowedPaths`, added-line code `leftovers` (`debugger`, `.only(`, `@ts-ignore`, `eslint-disable`, empty `TODO`/`FIXME`), and remaining `obsolete_hits` |
| `check-wave` | `0` `WAVE_OK`, `2` `WAVE_CONFLICT`, `1` error | Validates pairwise exact + prefix path disjointness across parallel wave tasks (`T002=a,b;T003=c,d`) |
| `new-run` | `0` `<run_id>`, `1` error | Allocates `.b3/autodev/runs/<YYYYMMDD-HHMM>-<slug>/` (with `-2` collision suffix) and writes `.b3/autodev/CURRENT` |
| `resolve-run` | `0` path, `1` `NO_ACTIVE_RUN`/error | Resolves `.b3/autodev/runs/<id>` from `-RunId`/`--run-id` or `CURRENT` (with legacy `.b3/autodev` fallback) |
| `list-runs` | `0` list | Lists runs newest-first with `[<run_status>]` and `*` marker on `CURRENT` |
| `prune` | `0` `PRUNE_OK`, `1` error | Keeps newest `Keep` (default `10`) `PASS` runs; never deletes `CURRENT` or non-`PASS` runs |
