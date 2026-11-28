# Research Ship Autonomous Workflow

Research-first delivery complementing [`ship.md`](ship.md); reads product profiles dynamically without embedded domain policy.

## Core Invariants & State Boundaries

- **Separated truth:** `RESEARCHED != VERIFIED != IMPLEMENTED != RELEASED`; `PR_MERGED != RUNTIME_SERVED != DEPLOYED`; `TASK_VERIFIED != DEPENDENCY_OUTPUT_AVAILABLE`.
- **Fail closed:** missing evidence, Owner decision, stale receipt/manifest, tool error, or unmet gate → `INCOMPLETE`/`FAIL`/`BLOCKED`, never `PASS`/`PR_READY`.
- **No fabrication:** never invent passages, editions, citations, witness outputs, Owner decisions, editorial approvals, or test passes.
- **Policy fidelity:** follow product policy literally (authorized AI editorial review; never add unrequested human gates or bypass policy).
- **Unit isolation:** if `U00k` hits an unresolved domain/Owner decision, mark `U00k` `blocked` and `continue independent eligible units`.

## Modes

- `status [<run_id>|--all]` (read-only): `b3 guard list-runs --namespace research-ship`/`resolve-run` + summarize `progress.md`.
- `resume [<run_id>]`: [`references/research-ship-resume.md`](references/research-ship-resume.md), reconcile Git + `b3 guard evidence-check`, continue eligible units.
- `research-only`|`research+implement`|`research+governed-release`|`existing-plan`: init `{RUN_DIR}` (`.b3/research-ship/runs/<run_id>/`), run A–K (local non-PR `research-only` stops after Phase H and skips Phases I–K).

## Lifecycle (Phases A–K)

Load [templates](references/research-ship-templates.md) on create; [gates](references/research-ship-gates.md) at E/H–K; [`references/context-routing.md`](references/context-routing.md) on demand for repo/G (`repo-evidence` only, [gates](references/research-ship-gates.md) §2).

### A. Preflight
- **Out:** `B3_HOME` (`B3_HOME` env → `.b3/home` → host global fallback → current repo), `PRODUCT_ROOT`, branch/HEAD, open PR on GitHub (`gh pr list --head <branch>`), `.b3/research-{profile.md,policy.json}`, `--protected-paths`, `initial_dirty_paths`, Parent-once [static-analysis](references/static-analysis.md) (when checks/impl apply), `{RUN_DIR}` (`b3 guard new-run --namespace research-ship --slug <slug>`).
- **Gate:** preserve `research/`, decisions, evidence; run `b3 guard check-worktree --expected-root <root> --require-isolated` ONLY on `ISOLATED_WRITES` (never block `research-only`/`SHARED_READ_ONLY` in Phase A; fall back to `SEQUENTIAL` when safe per [dispatch](references/dispatch-naming.md)); missing `B3_HOME`, unsafe isolated worktree failure, or dirty overlap → `BLOCKED`.

### B. Research Planning
- **Out:** critical-path ordered units `U001..U00N` (`research-plan.md`, or inline in `progress.md` for 1-unit): question, baseline, gaps, sources, domains, hard verified-output `depends_on`, disjoint `owned_files`, ACs, checks, implications.
- **Gate:** keep ledgers/manifests/`evidence-index.md`/authority single-writer ([dispatch](references/dispatch-naming.md)); Parent isolates ambiguous units per [clarification](references/clarification-gate.md) (`continue independent eligible units`) or `BLOCKED`.

### C. Source Discovery & Provenance
- **Out:** `evidence-index.md` + SHA-256 `{RUN_DIR}/evidence/sources.manifest` (`b3 guard evidence-check --write-manifest`). Run ready unit source checks continuously in `SHARED_READ_ONLY` (`dispatch-naming.md`); Parent merges `evidence-index.md` + manifest single-writer and sets `integration=output_ready` once artifact + `evidence-check` pass.
- **Gate:** index-first refs + digests; classify `primary`|`secondary-scholarly`|`repo-evidence`|`prior-verified`|`unverified`|`conflicting`; missing source → `EVIDENCE_MISSING` (`exit 1`, mark `incomplete`/`blocked` without guessing).

### D. Cross-Source Analysis
- **Out:** continuous `SHARED_READ_ONLY` analysis on ready units (`depends_on` `output_ready`, no artificial wave barrier) for agreement, contradictions, missing conditions, school differences, overgeneralizations, terminology.
- **Gate:** genuine disagreements stay `UNRESOLVED`/`DISPUTED` (`continue independent eligible units`; never force consensus); unsupported predicates block formalization.

### E. Independent Evidence Verification
- **Out:** verdict (`VERIFIED`|`DISPUTED`|`INCOMPLETE`) from fresh independent `SHARED_READ_ONLY` verifiers (`researcher != verifier`; [gates](references/research-ship-gates.md) §1, [dispatch](references/dispatch-naming.md)) via `TaskId=none`/`[]` + `--wave-reads`, admitted continuously via `b3 guard check-wave --partition` (§Parallel Research).
- **Gate:** isolate `EVIDENCE_STALE` (`exit 2`) or `DISPUTED` units for re-verify or C/D while verified peers advance (`continue independent eligible units`); `SINGLE_AGENT_LIMIT` blocks `PASS`/`VERIFIED`/`MERGE_AUTHORIZED` on `HIGH`/`CRITICAL` (`INCOMPLETE`, no `auto_merge`).

### F. Formalization & Knowledge Readiness
- **Out:** target (`research-doc`|`structured-knowledge`|`executable-predicate`|`witness-fixture`|`internal-only`|`impl-spec`|`release-candidate`|`WITHHELD`|`BLOCKED`). Completeness != publication; `WITHHELD`/`internal-only` stay private; missing Owner/authority pin blocks unit.

### G. Implementation (Skip in `research-only`)
- **Out:** verified commits via [`ship.md`](ship.md), [`references/dispatch-naming.md`](references/dispatch-naming.md), [`references/context-routing.md`](references/context-routing.md) (`repo-evidence` only), and [`../review-loop/strategy.md`](../review-loop/strategy.md).
- **Gate:** enforce `TASK_VERIFIED != DEPENDENCY_OUTPUT_AVAILABLE` (`output_ready` + `--verified-dirty-paths` in `SHARED_DISJOINT_WRITES`, **never** `git commit` in a shared WT while peer shared-WT writers remain active; `integrated` in Parent before starting dependents in `ISOLATED_WRITES`, without rebasing/mutating active peer WTs; 0 worker Git ops or nested subagents). `b3 guard mechanical-check` passes `--worker-bases` with `--worker-roots` when Parent `HEAD` advanced while peer WTs ran (`UNVERIFIED_COMBINED_ONLY` on ordinary disjoint tasks, `CALLER_ATTRIBUTED` via `--worker-changes`, `VERIFIED_PER_WORKER` via `--worker-roots`; escalate to `ISOLATED_WRITES`/`SEQUENTIAL` when strict proof is required). `WAVE_CONFLICT`/`WAVE_SEQUENTIAL`/`malformed_wave_output` → `SEQUENTIAL`; `WAVE_BASE_MISMATCH` → `BLOCKED`.

### H. Technical Verification & Independent Review / Editorial Gates
- **Out:** separate **Research**, **Engineering**, and **Editorial / Authority** verdicts (`b3-reviewer.md`, specialists, [gates](references/research-ship-gates.md) §2); offload static lint/guards pre-review per `static-analysis.md`. Green tests != source pass; fix blockers before Phase I.

### I. PR Lifecycle (Branch Readiness & Optional PR Publishing)
- **Out:** reconciled target (`main`, `develop`, `release/*`, `feature/*`, stacked) + `{RUN_DIR}/pr-body.md` (+ 1 PR on GitHub).
- **Gate:** confirm 0 blockers + green checks. Local/non-GitHub repos proceed to Phase J; on GitHub when publishing, reuse/open PR (`gh pr list --head <branch>`) and handle authorized PR feedback via `pr-feedback/SKILL.md` (thread resolve != editorial/release approval).

### J. Merge Eligibility Evaluation
- **Gate:** run `b3 guard merge-policy-check` against canonical trunk `.b3/research-policy.json` ([gates](references/research-ship-gates.md) §4 for flags/CI-receipt rules): `auto_merge: disabled` → `PR_READY` (`exit 2`); unverified remote / local-only mode → `LOCAL_ELIGIBLE_ONLY` (`exit 2`); provider outage → `PROVIDER_UNAVAILABLE` (`exit 2`); caller-only `CiStatus=PASS`, stale ref, unmet policy/CI/clean-tree/`INDEPENDENT` ledger (`SINGLE_AGENT_LIMIT`/`UNKNOWN`) → `MERGE_BLOCKED` (`exit 1`); all green under `auto_merge: authorized` → `MERGE_AUTHORIZED` (`mode=local|github`, `exit 0`).

### K. Authorized Auto-Merge & Post-Merge Verification
- **Gate:** on `MERGE_AUTHORIZED` (`exit 0`), merge and run `b3 guard merge-policy-check --post-merge` ([gates](references/research-ship-gates.md) §4 for `mode=github|local` flags), requiring `POST_MERGE_VERIFIED` (`mode=local|github`, `exit 0`). Reconcile artifacts/authority + `b3 guard evidence-check`; report `MERGED_VERIFIED` (`pr_status=PR_MERGED` when PR-backed, `runtime_served=NOT_VERIFIED`, `deployed=NOT_VERIFIED` unless verified).

## Parallel Research & Subagent Naming

- Schedule ready research units, source checks, fresh Phase E verifiers (`researcher != verifier`), and Phase G impl units continuously by critical path per [`references/dispatch-naming.md`](references/dispatch-naming.md): on each worker exit, verify output availability (`output_ready` / `integrated`) and, when `>=2` ready units exist or active workers are running, run `b3 guard check-wave --partition` (`--wave-specs`, `--wave-reads`, `--active-specs`, `--active-reads`, `--verified-dirty-paths`, `--protected-paths`, `--ignore-dirty-paths`, `--check-dirty-scope`), acting strictly on `admitted_tasks` (`wave|1|`) and queuing `deferred_tasks` across `SHARED_READ_ONLY`, `SHARED_DISJOINT_WRITES`, `ISOLATED_WRITES`, `SEQUENTIAL` (1 ready unit w/ 0 active workers runs sequentially keeping scope/dirty/commit guards). Isolate `DISPUTED`/`blocked`/`failed` units (`continue independent eligible units`), keep `evidence-index.md`, `sources.manifest`, ledgers, authority records, and PR mutations single-writer in Parent, record `last_wave:`, and use `b3-research-<slug>`/`b3-verify-<slug>`/`b3-impl-<task-id>` without nested subagents.
