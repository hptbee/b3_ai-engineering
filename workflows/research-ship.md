# Research Ship Autonomous Workflow

Research-first delivery complementing [`ship.md`](ship.md); reads product profiles dynamically without embedded domain policy.

## Core Invariants & State Boundaries

- **Separated truth:** `RESEARCHED != VERIFIED != IMPLEMENTED != RELEASED`; `PR_MERGED != RUNTIME_SERVED != DEPLOYED`.
- **Fail closed:** missing evidence, Owner decision, stale receipt/manifest, tool error, or unmet gate → `INCOMPLETE`/`FAIL`/`BLOCKED`, never `PASS`/`PR_READY`.
- **No fabrication:** never invent passages, editions, citations, witness outputs, Owner decisions, editorial approvals, or test passes.
- **Policy fidelity:** follow product policy literally (authorized AI editorial review; never add unrequested human gates or bypass policy).
- **Unit isolation:** if `U00k` hits an unresolved domain/Owner decision, mark `U00k` `blocked` and `continue independent eligible units`.

## Modes

- `status [<run_id>|--all]` (read-only): `b3-guard.{ps1,sh} list-runs -Namespace research-ship`/`resolve-run` + summarize `progress.md`.
- `resume [<run_id>]`: [`references/research-ship-resume.md`](references/research-ship-resume.md), reconcile Git + `evidence-check`, continue eligible units.
- `research-only`|`research+implement`|`research+governed-release`|`existing-plan`: init `{RUN_DIR}` (`.b3/research-ship/runs/<run_id>/`), run A–K.

## Lifecycle (Phases A–K)

Load [templates](references/research-ship-templates.md) on create; [gates](references/research-ship-gates.md) at E/H–K; [`references/context-routing.md`](references/context-routing.md) on demand for repo/G (`repo-evidence` only, [gates](references/research-ship-gates.md) §2).

### A. Preflight
- **Out:** `B3_HOME` (`B3_HOME` env → `.b3/home` → host global fallback → current repo), `PRODUCT_ROOT`, branch/HEAD, open PR on GitHub (`gh pr list --head <branch>`), `.b3/research-{profile.md,policy.json}`, `-ProtectedPaths`, `initial_dirty_paths`, `{RUN_DIR}` (`b3-guard new-run -Namespace research-ship -Slug <slug>`).
- **Gate:** preserve `research/`, decisions, evidence; verify `ISOLATED_WRITES` via `check-worktree -RequireIsolated` ([dispatch](references/dispatch-naming.md)); missing `B3_HOME`, worktree failure, or dirty overlap → `BLOCKED`.

### B. Research Planning
- **Out:** units `U001..U00N` (`research-plan.md`, or inline in `progress.md` for 1-unit): question, baseline, gaps, sources, domains, `depends_on`, disjoint `owned_files`, ACs, checks, implications.
- **Gate:** keep ledgers/manifests/`evidence-index.md`/authority single-writer ([dispatch](references/dispatch-naming.md)); isolate ambiguous units (`continue independent eligible units`) or `BLOCKED`.

### C. Source Discovery & Provenance
- **Out:** `evidence-index.md` + SHA-256 `{RUN_DIR}/evidence/sources.manifest` (`b3-guard evidence-check -WriteManifest`).
- **Gate:** index-first refs + digests; classify `primary`|`secondary-scholarly`|`repo-evidence`|`prior-verified`|`unverified`|`conflicting`; missing source → `EVIDENCE_MISSING` (`exit 1`, mark `incomplete`/`blocked` without guessing).

### D. Cross-Source Analysis
- **Out:** unit notes on agreement, contradictions, missing conditions, school differences, overgeneralizations, terminology.
- **Gate:** genuine disagreements stay `UNRESOLVED`/`DISPUTED` (never force consensus); unsupported predicates block formalization.

### E. Independent Evidence Verification
- **Out:** verdict (`VERIFIED`|`DISPUTED`|`INCOMPLETE`) from fresh `SHARED_READ_ONLY` verifiers ([gates](references/research-ship-gates.md) §1, [dispatch](references/dispatch-naming.md)) using `TaskId=none`/`[]` + `-WaveReads` via `check-wave -Partition` (`wave|N|...`).
- **Gate:** `EVIDENCE_STALE` (`exit 2`) or `DISPUTED` → re-verify or C/D; `SINGLE_AGENT_LIMIT` blocks `PASS`/`VERIFIED`/`MERGE_AUTHORIZED` on `HIGH`/`CRITICAL` (`INCOMPLETE`, no `auto_merge`).

### F. Formalization & Knowledge Readiness
- **Out:** target (`research-doc`|`structured-knowledge`|`executable-predicate`|`witness-fixture`|`internal-only`|`impl-spec`|`release-candidate`|`WITHHELD`|`BLOCKED`). Completeness != publication; `WITHHELD`/`internal-only` stay private; missing Owner/authority pin blocks unit.

### G. Implementation (Skip in `research-only`)
- **Out:** verified commits via [`ship.md`](ship.md), [`references/dispatch-naming.md`](references/dispatch-naming.md), [`references/context-routing.md`](references/context-routing.md) (`repo-evidence` only), and [`../review-loop/strategy.md`](../review-loop/strategy.md).
- **Gate:** in `SHARED_DISJOINT_WRITES`, no worker Git ops or nested subagents; `mechanical-check` allows `UNVERIFIED_COMBINED_ONLY` on ordinary disjoint tasks (`CALLER_ATTRIBUTED` via `-WorkerChanges` or `VERIFIED_PER_WORKER` via `-WorkerRoots` when attributed; escalate to `ISOLATED_WRITES`/`SEQUENTIAL` if strict proof required). `WAVE_CONFLICT`/`WAVE_SEQUENTIAL`/`malformed_wave_output` → `SEQUENTIAL`; `WAVE_BASE_MISMATCH` → `BLOCKED`.

### H. Technical Verification & Independent Review / Editorial Gates
- **Out:** separate **Research**, **Engineering**, and **Editorial / Authority** verdicts (`b3-reviewer.md`, specialists, [gates](references/research-ship-gates.md) §2). Green tests != source pass; fix blockers before Phase I.

### I. PR Lifecycle (Branch Readiness & Optional PR Publishing)
- **Out:** reconciled target (`main`, `develop`, `release/*`, `feature/*`, stacked) + `{RUN_DIR}/pr-body.md` (+ 1 PR on GitHub).
- **Gate:** confirm 0 blockers + green checks. Local/non-GitHub repos proceed to Phase J; on GitHub when publishing, reuse/open PR (`gh pr list --head <branch>`) and handle authorized PR feedback via `pr-feedback/SKILL.md` (thread resolve != editorial/release approval).

### J. Merge Eligibility Evaluation
- **Gate:** run `b3-guard merge-policy-check` ([gates](references/research-ship-gates.md) §4) against canonical trunk `.b3/research-policy.json` (`-PrNumber <N>` on GitHub; `-ReceiptPath`/ledger receipt on local `require_ci`). `auto_merge: disabled` → `PR_READY` (`exit 2`); `-LocalOnly`, or remote-backed repo without provider verification → `LOCAL_ELIGIBLE_ONLY` (`exit 2`); provider outage/`-RequireRemoteCi` without provider → `PROVIDER_UNAVAILABLE` (`exit 2`); caller-only `CiStatus=PASS`, stale ref, unmet policy/CI/clean-tree/`INDEPENDENT` ledger (`SINGLE_AGENT_LIMIT`/`UNKNOWN`) → `MERGE_BLOCKED` (`exit 1`); all green under `auto_merge: authorized` (local-only or verified provider PR) → `MERGE_AUTHORIZED` (`mode=local|github`, `exit 0`).

### K. Authorized Auto-Merge & Post-Merge Verification
- **Gate:** on `MERGE_AUTHORIZED` (`exit 0`), merge and run `b3-guard merge-policy-check -PostMerge -MainRef <target-ref>` (`-PrNumber <N>` for `mode=github`, or `-MergedSha <sha> -HeadSha <sha> [-BaseSha <sha>]` for `mode=local`), requiring `POST_MERGE_VERIFIED` (`mode=local|github`, `exit 0`). Reconcile artifacts/authority + `evidence-check`; report `MERGED_VERIFIED` (`pr_status=PR_MERGED` when PR-backed, `runtime_served=NOT_VERIFIED`, `deployed=NOT_VERIFIED` unless verified).

## Parallel Research & Subagent Naming

- Schedule ready units per [`references/dispatch-naming.md`](references/dispatch-naming.md) (`check-wave -Partition` with `-ProtectedPaths`, `-IgnoreDirtyPaths`, `-CheckDirtyScope`; strict `wave|N|...` across `SHARED_READ_ONLY`, `SHARED_DISJOINT_WRITES`, `ISOLATED_WRITES`, `SEQUENTIAL`). Isolate blocked/failed units (`continue independent eligible units`), keep ledgers/manifests/authority single-writer, record `last_wave:`, and use `b3-research-<slug>`/`b3-impl-<task-id>` without nested subagents.
