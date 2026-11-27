# Subagent dispatch, adaptive scheduling & orchestration (on-demand)

Single canonical orchestration contract inherited by all 14 B3 commands, workflows, and `/b3-review-loop`. Load once at dispatch; never copy into subagent briefs.

- **Canonical roles & aliases:** Keep `agents/b3-*.md` stems/`name:` stable (`b3-reviewer`, `b3-fixer`, `b3-{security,architecture,performance}-reviewer`). Prefer lowercase kebab-case `b3-impl-<task-id>` (impl) and `b3-research-<slug>` (research) when the host supports custom spawn names; never block on naming.
- **Session IDs & no nesting:** Store host-returned agent IDs separately from aliases. Workers execute directly and **never** spawn nested subagents. Applies to B3 subagent IDs only, not product runtime workers or legacy `.b3/autodev/`.

## Optional model preferences

- Read once per dispatch phase: `<project>/.b3/models.md`, then `~/.b3/models.md` (`B3_MODELS_PERSONAL`). Precedence: user selection > project > personal > `auto`.
- Applies to `planning`, `debugging`, `implementation`, `b3-reviewer`, `b3-fixer`, and specialist reviewers.
- **Single-task fast-path:** 1-unit `XS` + `inline` runs inline on `main` when `implementation` is unset/`auto` (or matches `main`). Dispatch `b3-impl-<task-id>` when a custom model differs, or when size `>= S`, `notes`/`detailed`, or multi-unit waves apply. Apply preferred models only where supported; never edit host settings or committed `agents/*.md` (`model: inherit`) or claim unverified switches.

## Adaptive scheduling, continuous dispatch & concurrency

- **Adaptive scheduling:** Trivial 1-unit `XS` work runs inline without DAG bureaucracy. Multi-unit/complex work builds a minimal dependency graph, dispatches ready independent units via the cheapest safe isolation mode, and **releases newly unblocked dependents immediately** once prerequisites verify (retaining barriers only for shared integration or commits).
- **Adaptive concurrency (no fixed `3`/`4` limits):** Scale concurrency dynamically by independent work count, context budget, host limits, CPU/memory/rate limits, and net cost/throughput benefit — never spawn extra workers unless overhead is justified. `b3 guard check-wave --partition` defaults to host `available_parallelism` (`4..=16`, explicit `--max-concurrency 1..64`).
- **Context-aware dispatch & reuse:** Pass lean `<=25L` packets (`approach`/targets minus `## Inspected`, `files`/`read_only_deps`, 1L `context_hint:`, matched skill; never paste orchestrator docs). Reuse optional MCPs (`context-routing.md`) when healthy without making MCP mandatory; require compact structured returns. Reuse an existing subsystem worker when context stays relevant and independence is not needed; always use a fresh worker for independent reviews. Parent owns shared state, integration, commits, and external PR mutations.

## 4 adaptive isolation modes (least-expensive-safe)

1. `SHARED_READ_ONLY`: concurrent research, discovery, analysis, evidence verification, and review via `check-wave --partition` (`TaskId=none` or `[]` + `--wave-reads`). Readers run in the existing worktree without temp files, dummy write paths, extra worktrees, or commits; mixed reader/writer waves detect RW conflicts while preserving reviewer independence.
2. `SHARED_DISJOINT_WRITES`: concurrent writers in one worktree **only** when: (a) `check-wave --partition` clears non-`.` disjoint writes with zero RW/dirty/protected conflicts; (b) build/test/lint commands have no colliding side effects (caches, codegen, DBs, ports); (c) workers **never** stage, commit, checkout, merge, rebase, stash, or mutate Git state (no nested subagents); (d) Parent runs pre-integration `mechanical-check` and post-integration `verify-run` + cross-unit review (`review-loop/strategy.md`). Path ownership != OS isolation; escalate to `ISOLATED_WRITES`/`SEQUENTIAL` when strict isolation is needed.
3. `ISOLATED_WRITES`: separate `git worktree` per writer for high risk, broad/uncertain scope, colliding side effects, separate commits, or strict attribution. Verify via `b3 guard check-worktree --repo-root <wt> --require-isolated --expected-root <parent> --expected-base-sha <sha> --peer-roots <other_wts>`. `WORKTREE_OK` alone proves identity, not full isolation (full isolation requires `--require-isolated` + `--expected-root` + `--peer-roots` proving distinct `linked=true` `isolated=true` non-nested roots). Fall back (`worktree_identity_failed` → `SEQUENTIAL`) on failure.
4. `SEQUENTIAL`: fallback when parallel dispatch is unjustified or blocked (`single_ready_task`, `trivial_overhead`, `dependency_chain`, `shared_write_conflict`, `read_write_conflict`, `unsafe_shared_side_effects`, `dirty_scope_conflict`, `no_host_isolation`, `sequential_host_fallback`, `malformed_wave_output`, `worktree_identity_failed`, `bounded_concurrency`). Disclose reason code when meaningful independent work exists.

## Pre-dispatch gate, canonical ownership & integration

- **Wave & dirty-scope gate:** Before parallel waves, run `b3 guard check-wave --partition --wave-specs <TaskId=paths;...> [--wave-reads <TaskId=paths;...>] [--protected-paths <csv>] [--ignore-dirty-paths <initial_dirty_paths>] [--check-dirty-scope] [--max-concurrency 1..64] [--expected-base-sha <sha>]` (`TaskId=none`/`[]` for pure readers):
  - Reject `.` root ownership for concurrent writers; `--protected-paths` guards `.git/`, `.b3/`, shared ledgers/manifests, `evidence-index.md`, authority records, and product `single_writer_paths` (rejecting symlink/junction aliases).
  - Dirty-scope checks separate `initial_dirty_paths`, authorized worker edits, and unexpected edits (`HEAD` match != tree freshness); isolate conflicts without resetting user/worker work.
  - Parse strictly `wave|N|PARALLEL|agents=<N>|tasks=<csv>|...` or `wave|N|SEQUENTIAL|...` (malformed → `SEQUENTIAL` `malformed_wave_output` or `BLOCKED`).
- **Canonical `mechanical-check` ownership contract:** Before staging/committing, run `b3 guard mechanical-check --base-sha <sha> --allowed-paths <wave_owned> [--wave-specs <TaskId=owned;...>] [--worker-changes <TaskId=changed;...> | --worker-roots <TaskId=wt;...>] [--protected-paths <csv>] [--dirty-digests <path=sha256|DELETED;...>] [--ignore-dirty-paths <initial_dirty_paths>] [--obsoletes <csv>]`:
  - `--protected-paths` flags `protected_violations`; `--dirty-digests` (`;` entries) detects `dirty_tamper`.
  - `ownership_verification` statuses (`--wave-specs`):
    - `UNVERIFIED_COMBINED_ONLY` (`exit 0`): `--wave-specs` without `--worker-changes`/`--worker-roots`; valid for ordinary `SHARED_DISJOINT_WRITES`, never claim per-worker proof from combined diff alone.
    - `CALLER_ATTRIBUTED` (`exit 0`): `--worker-changes` covers all edits within each worker's declared paths.
    - `VERIFIED_PER_WORKER` (`exit 0`): `--worker-roots` verifies each isolated linked worktree's diff and integrated content against declared paths.
    - `PARTIAL_ATTRIBUTION` (`exit 2`): omits one or more wave workers (`missing_worker`).
    - `VIOLATION` (`exit 2`): cross-worker, unowned, unattributed, phantom, content-mismatch, protected-path, or `dirty_tamper` violation.
- **Host fallback & single-writer integration (`Cursor`, `Claude Code`, `Codex`, `Antigravity`):** Without parallel subagents or required isolation, degrade to `SEQUENTIAL` (`no_host_isolation`/`sequential_host_fallback`; never report `PARALLEL`; `SHARED_READ_ONLY` may still run concurrently when supported). Keep shared state (`progress.md`, `findings.md`, ledgers/manifests, authority pins, `review-ledger`), external PR mutations, and `b3 guard precommit` single-writer. On partial failure, preserve valid verified edits and isolate failing units (never `git reset`). Post-wave/unit: recompute dependencies, run `check-freshness`/dirty scope, release newly unblocked units, and run post-integration `verify-run` + cross-unit review (`review-loop/strategy.md`) after parallel code waves.
- **Wave status (`last_wave:` / report — actual executed concurrency only):**
  - `dispatch=PARALLEL agents=<actual_N> isolation=<SHARED_READ_ONLY|SHARED_DISJOINT_WRITES|ISOLATED_WRITES>`
  - `dispatch=SEQUENTIAL reason=<reason_code>`
