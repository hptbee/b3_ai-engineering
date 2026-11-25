# Subagent dispatch naming (load only at spawn)

This is an on-demand contract for B3 orchestrators, **not** a global rule. Read once only when dispatching; do not copy it into each subagent brief.

- **Canonical roles:** Keep `agents/b3-*.md` filename stems and YAML `name:` stable (for example `b3-reviewer`, `b3-fixer`, `b3-security-reviewer`, `b3-architecture-reviewer`, `b3-performance-reviewer`).
- **Logical aliases:** Prefer `b3-impl-<task-id>` (e.g. `b3-impl-t002`) for implementation and `b3-research-<slug>` for research. Use lowercase ASCII kebab-case and a stable, unique task key; shorten long slugs deterministically if the host imposes a name limit, without collisions.
- **Host fallback:** Request the logical alias as a spawn/display name **only if the host API supports custom names**. Never pass unsupported `Role`/display fields or block dispatch because of naming. A host-generated name is acceptable.
- **Resume:** Keep the logical alias separate from the **host-returned agent ID**, when available. Store that ID in run state and resume by ID, not by alias. If there is no resumable ID, use a fresh agent (or record the existing single-agent independence limitation).
- **Scope:** Apply this convention to B3 subagent identifiers, not ordinary prose, application runtime workers, legacy `.b3/autodev/` checkpoints, or historical decision records. Runtime behavior and reviewer independence take priority over cosmetic naming.
## Optional model preferences

- Read once per dispatch phase (on demand, not globally or per subagent): check `<project>/.b3/models.md`, then `~/.b3/models.md` (or `B3_MODELS_PERSONAL`).
- Applies advisories for `planning`, `implementation`, `b3-reviewer`, `b3-fixer`, and specialist review agents (`b3-security-reviewer`, `b3-architecture-reviewer`, `b3-performance-reviewer`).
- Precedence: explicit user selection > `<project>/.b3/models.md` > `~/.b3/models.md` > native `auto`.
- Dispatch `b3-impl-<task-id>` even for single-task builds when the host supports subagents so a custom `implementation` model applies independently of `main` rather than falling back inline.
- Apply a preferred model **only** when the active host supports selecting a model on dispatch; otherwise inherit the native/parent model. Never block work on missing or malformed preference files, never edit IDE settings or committed `agents/*.md` (`model: inherit`), and never claim a model switch occurred without evidence.

## Automatic wave scheduling

- **Default evaluation:** On every ready queue (`pending`, `depends_on` done), evaluate parallel vs. sequential dispatch automatically — never require the user to ask for parallel agents.
- **Deterministic pre-dispatch gate:** Run `b3-guard.{ps1,sh} check-wave -Partition -WaveSpecs <TaskId=paths;...> [-WaveReads <TaskId=paths;...>] [-MaxConcurrency 1..4] [-ExpectedBaseSha <sha>]` (Bash: `--partition --wave-specs --wave-reads --max-concurrency --expected-base-sha`; default `-MaxConcurrency` `3`, cap `4` for large independent batches):
  - `WAVE_OK` → dispatch wave 1 in parallel (`PARALLEL`).
  - `WAVE_PARTITIONED` → dispatch disjoint wave 1 in parallel first; defer conflicting/capped tasks to subsequent waves after integration.
  - `WAVE_SEQUENTIAL` / `WAVE_CONFLICT` → degrade to sequential (`SEQUENTIAL`).
  - `WAVE_BASE_MISMATCH` (stale base SHA, dirty overlap, or mid-git op) → fail closed (`BLOCKED` or re-scope).
- **Economic overhead threshold:** Use `SEQUENTIAL` when `<=1` ready task (`single_ready_task`), trivial single-file/tiny overhead (`trivial_overhead`), or unpartitioned dependency chains (`dependency_chain`).
- **Host isolation fallback (Cursor, Claude Code, Codex, Antigravity):** If the host lacks parallel isolated subagents or worktree isolation (`check-worktree`) for write scopes, degrade cleanly to `SEQUENTIAL` (`no_host_isolation` / `sequential_host_fallback`) — never report `PARALLEL` when execution was sequential. Read-only research/review units may still run in parallel when the host supports concurrent subagent calls and outputs remain disjoint.
- **Partial failure & single-writer serialization:** When a parallel wave partially fails, preserve valid verified outputs and isolate/recover only failing units (never `git reset` valid work). Serialize shared state (`progress.md`, `findings.md`, shared ledgers/manifests, authority pins, `review-ledger`) and sequential commits (`b3-guard precommit`) through the single parent writer. Run post-integration `b3-guard verify-run` and cross-unit review (`review-loop/strategy.md`) after parallel code waves.
- **Wave status format (`last_wave:` / report):**
  - `dispatch=PARALLEL agents=<N> reason=<disjoint_writes|partitioned_wave|independent_research_units>`
  - `dispatch=SEQUENTIAL reason=<single_ready_task|trivial_overhead|dependency_chain|shared_write_conflict|read_write_conflict|dirty_worktree|no_host_isolation|sequential_host_fallback|bounded_concurrency>`
