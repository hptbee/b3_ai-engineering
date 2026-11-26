# Subagent dispatch naming & wave orchestration (load only at spawn)

This is an on-demand contract for B3 orchestrators, **not** a global rule. Read once when dispatching; never copy it into subagent briefs.

- **Canonical roles:** Keep `agents/b3-*.md` stems and YAML `name:` stable (`b3-reviewer`, `b3-fixer`, `b3-security-reviewer`, `b3-architecture-reviewer`, `b3-performance-reviewer`).
- **Logical aliases:** Prefer `b3-impl-<task-id>` (e.g. `b3-impl-t002`) for implementation and `b3-research-<slug>` for research in lowercase ASCII kebab-case; shorten long slugs deterministically without collisions if a host caps name length.
- **Host fallback:** Request the logical alias as a spawn/display name **only if the host API supports custom names**. Never pass unsupported fields or block dispatch on naming; host-generated names are fine.
- **Resume & no nested fan-out:** Store the **host-returned agent ID** separately from the logical alias and resume by ID (or spawn a fresh agent when unresumable). Dispatched workers execute their assigned unit directly and **never** spawn nested subagents.
- **Scope:** Applies only to B3 subagent identifiers, not product runtime workers, legacy `.b3/autodev/` files, or historical records.

## Optional model preferences

- Read once per dispatch phase (on demand): check `<project>/.b3/models.md`, then `~/.b3/models.md` (or `B3_MODELS_PERSONAL`).
- Applies advisories for `planning`, `debugging`, `implementation`, `b3-reviewer`, `b3-fixer`, and specialist reviewers (`b3-security-reviewer`, `b3-architecture-reviewer`, `b3-performance-reviewer`).
- Precedence: explicit user selection > `<project>/.b3/models.md` > `~/.b3/models.md` > native `auto`.
- **Single-task Build rule:** Allow 1-task `XS` + `inline` builds to run inline on `main` when the `implementation` model preference is unset or `auto` (or matches `main`). Dispatch `b3-impl-<task-id>` whenever a custom `implementation` model differs from `main`, or whenever size `>= S`, depth `notes`/`detailed`, or multi-task waves apply (when the host supports subagents).
- Apply a preferred model **only** when the active host supports model selection at dispatch; otherwise inherit the native/parent model. Never block work on missing or malformed preference files, edit IDE settings or committed `agents/*.md` (`model: inherit`), or claim a model switch without evidence.

## Automatic wave scheduling & isolation modes

- **Default evaluation:** On every ready queue (`pending`, `depends_on` done), evaluate parallel vs. sequential dispatch automatically without waiting for user prompting.
- **4 adaptive isolation modes (least-expensive-safe):**
  1. `SHARED_READ_ONLY`: concurrent read-only research, analysis, evidence verification, and review via `check-wave -Partition` with empty write scopes (`TaskId=none` or `[]`) and declared `-WaveReads`. Readers run in the existing worktree without temp files, dummy write paths, separate worktrees, or commits, returning findings to Parent; mixed reader/writer waves detect RW conflicts via partitioning while preserving reviewer independence and single-writer integration.
  2. `SHARED_DISJOINT_WRITES`: concurrent writers in the same worktree **only** when: (a) `check-wave -Partition` (`-WaveReads`, `-ProtectedPaths`, `-IgnoreDirtyPaths`, `-CheckDirtyScope`, `-ExpectedBaseSha`) clears non-`.` disjoint writes with zero RW/dirty/protected conflicts; (b) build/test/lint commands have no colliding shared side effects (caches, codegen, DBs); (c) workers **never** stage, commit, checkout, merge, rebase, stash, or mutate shared Git state (and never spawn nested subagents); (d) Parent runs pre-integration `mechanical-check` (wave scope + ownership rules below) and post-integration `verify-run` + cross-unit review (`review-loop/strategy.md`). Declared path ownership != OS filesystem isolation; keep `SHARED_DISJOINT_WRITES` for safe ordinary tasks, and escalate to `ISOLATED_WRITES` or `SEQUENTIAL` when strict per-worker isolation/attribution is required.
  3. `ISOLATED_WRITES`: separate `git worktree` per writer for high risk, broad/uncertain scopes, colliding build/test side effects, separate branch/commit needs, or strict per-worker isolation. Verify every worktree via `b3-guard check-worktree -RepoRoot <wt> -RequireIsolated -ExpectedRoot <parent> -ExpectedBaseSha <sha> -PeerRoots <other_wts>` (Bash: `--require-isolated`). `WORKTREE_OK` verifies worktree identity, not full isolation (full isolation requires `-RequireIsolated` + `-ExpectedRoot` + `-PeerRoots` proving distinct `linked=true` `isolated=true` roots never equal to or nested inside parent/peer worktrees; non-isolation callers stay intact). Fall back (`worktree_identity_failed` → `SEQUENTIAL`) if isolation fails.
  4. `SEQUENTIAL`: automatic fallback when safe parallel execution is unjustified or unavailable (`single_ready_task`, `trivial_overhead`, `dependency_chain`, `shared_write_conflict`, `read_write_conflict`, `unsafe_shared_side_effects`, `dirty_scope_conflict`, `no_host_isolation`, `sequential_host_fallback`, `malformed_wave_output`, `worktree_identity_failed`, `bounded_concurrency`).

## Pre-dispatch gate, canonical ownership check & integration

- **Deterministic wave & dirty-scope gate:** Before every parallel wave, run `b3-guard.{ps1,sh} check-wave -Partition -WaveSpecs <TaskId=paths;...> [-WaveReads <TaskId=paths;...>] [-ProtectedPaths <csv>] [-IgnoreDirtyPaths <initial_dirty_paths>] [-CheckDirtyScope] [-MaxConcurrency 1..4] [-ExpectedBaseSha <sha>]` (default `-MaxConcurrency 3`, cap `4`; `TaskId=none` or `[]` marks pure readers):
  - Reject `.` root ownership for concurrent writers; `-ProtectedPaths` protects `.git/`, `.b3/`, shared ledgers/manifests, `evidence-index.md`, authority records, and product `single_writer_paths` (rejecting unsafe symlink/junction aliases).
  - Dirty-scope checks distinguish `initial_dirty_paths`, authorized worker edits, and unexpected edits (`HEAD` match alone != tree freshness); isolate conflicting tasks without resetting user/worker work.
  - Parse strictly the selected `wave|N|PARALLEL|agents=<N>|tasks=<csv>|...` or `wave|N|SEQUENTIAL|...` record (never infer from `WAVE_OK`/`WAVE_PARTITIONED`; malformed output → `SEQUENTIAL` `malformed_wave_output` or `BLOCKED`).
- **Canonical `mechanical-check` wave & per-worker ownership contract (single source of truth):**
  Before staging/committing a wave, run `b3-guard.{ps1,sh} mechanical-check -BaseSha <sha> -AllowedPaths <wave_owned> [-WaveSpecs <TaskId=owned;...>] [-WorkerChanges <TaskId=changed;...> | -WorkerRoots <TaskId=wt;...>] [-ProtectedPaths <csv>] [-DirtyDigests <path=sha256|DELETED;...>] [-IgnoreDirtyPaths <initial_dirty_paths>] [-Obsoletes <csv>]`:
  - `-ProtectedPaths` flags protected-path hits (`protected_violations`); `-DirtyDigests` (`;` entries) detects mutations to pre-existing `initial_dirty_paths` (`dirty_tamper`).
  - `ownership_verification` statuses when `-WaveSpecs` is supplied:
    - `UNVERIFIED_COMBINED_ONLY` (`exit 0` when wave checks pass): `-WaveSpecs` without `-WorkerChanges`/`-WorkerRoots`. Valid for ordinary `SHARED_DISJOINT_WRITES` wave validation, but never claim individual per-worker ownership was verified from a combined diff alone.
    - `CALLER_ATTRIBUTED` (`exit 0`): `-WorkerChanges` (host edit evidence or attributable changesets) covers all wave edits within each worker's declared paths.
    - `VERIFIED_PER_WORKER` (`exit 0`): `-WorkerRoots` verifies each isolated linked worktree's diff and integrated file content against its declared paths.
    - `PARTIAL_ATTRIBUTION` (`exit 2`): `-WorkerChanges` or `-WorkerRoots` omits one or more wave workers (`missing_worker`).
    - `VIOLATION` (`exit 2`): cross-worker, unowned, unattributed, phantom, content-mismatch, protected-path, or `dirty_tamper` violation.
- **Host fallback & single-writer integration (`Cursor`, `Claude Code`, `Codex`, `Antigravity`):** If the host lacks parallel subagents or required write separation, degrade to `SEQUENTIAL` (`no_host_isolation` / `sequential_host_fallback`) and never report `PARALLEL` when sequential (`SHARED_READ_ONLY` may still run concurrently when supported). Shared state (`progress.md`, `findings.md`, ledgers/manifests, authority pins, `review-ledger`) and `b3-guard precommit` stay single-writer. On partial failure, preserve valid verified edits and isolate failing units (never `git reset`). After each wave, recompute dependencies, `check-freshness`/dirty scope, and `check-wave -Partition`; parallel code waves also run combined post-integration `verify-run` + cross-unit review (`review-loop/strategy.md`).
- **Wave status format (`last_wave:` / report — actual executed concurrency only):**
  - `dispatch=PARALLEL agents=<actual_N> isolation=<SHARED_READ_ONLY|SHARED_DISJOINT_WRITES|ISOLATED_WRITES>`
  - `dispatch=SEQUENTIAL reason=<single_ready_task|trivial_overhead|dependency_chain|shared_write_conflict|read_write_conflict|unsafe_shared_side_effects|dirty_scope_conflict|no_host_isolation|sequential_host_fallback|malformed_wave_output|worktree_identity_failed|bounded_concurrency>`
