# Research Ship Autonomous Workflow

Research-first delivery complementing [`ship.md`](ship.md); read product profiles dynamically (no embedded domain policy).

## Core Invariants & State Boundaries

- **Separated truth:** `RESEARCHED != VERIFIED != IMPLEMENTED != RELEASED`; `PR_MERGED != RUNTIME_SERVED != DEPLOYED`.
- **Fail closed:** missing evidence, Owner decision, stale receipt/manifest, tool error, or unmet gate → `INCOMPLETE`/`FAIL`/`BLOCKED`, never `PASS`/`PR_READY`.
- **No fabrication:** never invent passages, editions, citations, witness outputs, Owner decisions, editorial approvals, or test passes.
- **No human gate override:** follow product policy literally (use authorized AI editorial review; never add extra human gates or bypass policy).
- **Unit isolation:** if `U00k` hits an unresolved domain/Owner decision, mark `U00k` `blocked` and `continue independent eligible units`.

## Modes

- `status [<run_id>|--all]` (read-only): `b3-guard.{ps1,sh} list-runs -Namespace research-ship`/`resolve-run` + summarize `progress.md`.
- `resume [<run_id>]`: [`references/research-ship-resume.md`](references/research-ship-resume.md), reconcile Git+`evidence-check`, continue eligible units (never restart verified units).
- `research-only`|`research+implement`|`research+governed-release`|`existing-plan`: init `{RUN_DIR}` (`.b3/research-ship/runs/<run_id>/`), run A–K.

## Lifecycle (Phases A–K)

Load [templates](references/research-ship-templates.md) on create; [gates](references/research-ship-gates.md) at E/H–K; [context-routing](references/context-routing.md) on demand for repo/G (`repo-evidence` only, [gates](references/research-ship-gates.md) §2).

### A. Preflight
- **In:** prompt/plan, repo. **Out:** `B3_HOME`, `PRODUCT_ROOT`, branch/HEAD, open PR (`gh pr list --head <branch>`), `.b3/research-{profile.md,policy.json}`, protected/single-writer paths, `initial_dirty_paths`, `{RUN_DIR}`.
- **Readiness:** `b3-guard new-run -Namespace research-ship -Slug <slug>` (unless resuming); record `initial_dirty_paths`, `ProtectedPaths` (`.git/`, `.b3/`, `evidence-index.md`, manifests, authority); `ISOLATED_WRITES` runs `check-worktree -RequireIsolated -ExpectedRoot <parent> -PeerRoots <other_wts>` (`WORKTREE_OK` = identity only unless `linked=true`/`isolated=true` non-nested roots; non-isolation callers intact; fail→`worktree_identity_failed`/`SEQUENTIAL`); preserve `research/`, decisions, evidence.
- **Failure / Recovery:** missing `B3_HOME`, worktree failure, or dirty overlap → `BLOCKED` (never reset user work).

### B. Research Planning
- **In:** request + preflight. **Out:** units `U001..U00N` (`research-plan.md`, or inline in `progress.md` for 1-unit): question, baseline, gaps, sources, domains, deps, ACs, checks, implications.
- **Readiness:** disjoint `owned_files`/`write_paths`, single-writer ledgers/manifests/`evidence-index.md`/authority pins, ready for automatic waves ([dispatch](references/dispatch-naming.md)).
- **Failure / Recovery:** ambiguous domain decision → split blocked unit (`continue independent eligible units`) or `BLOCKED`; oversized campaign → partition cohesive units.

### C. Source Discovery & Provenance
- **In:** unit specs. **Out:** `evidence-index.md` + SHA-256 `{RUN_DIR}/evidence/sources.manifest` (`b3-guard evidence-check -WriteManifest`).
- **Readiness:** index-first retrieval (refs+digests); classify claims: `primary`|`secondary-scholarly`|`repo-evidence`|`prior-verified`|`unverified`|`conflicting`; keep attribution, conditions, uncertainty.
- **Failure / Recovery:** unavailable source → `unverified`/`EVIDENCE_MISSING` (`exit 1`); re-scope or mark unit `incomplete`/`blocked` without guessing.

### D. Cross-Source Analysis
- **In:** indexed sources. **Out:** unit notes: agreement, contradictions, missing conditions, school diffs, overgeneralizations, terminology, context.
- **Readiness:** genuine disagreements stay `UNRESOLVED`/`DISPUTED` (never force consensus).
- **Failure / Recovery:** unsupported predicate/missing operand → `UNRESOLVED`, block formalization.

### E. Independent Evidence Verification
- **In:** claims + `evidence-index.md` + `sources.manifest`. **Out:** verdict (`VERIFIED`|`DISPUTED`|`INCOMPLETE`).
- **Readiness:** dispatch fresh `SHARED_READ_ONLY` verifiers ([gates](references/research-ship-gates.md)) with refs+fingerprints (`check-wave -Partition` with `TaskId=none`/`[]`+`-WaveReads`; no temp/dummy writes/worktrees/commits, findings→Parent, mixed waves catch RW conflicts, preserves reviewer independence & single-writer integration); check fidelity, provenance, conditions, contradictions, inferences.
- **Failure / Recovery:** `EVIDENCE_STALE` (`exit 2`) or `DISPUTED` → re-verify or C/D; no isolation → `SINGLE_AGENT_LIMIT` (blocks `PASS`/`VERIFIED`/`MERGE_AUTHORIZED` on `HIGH`/`CRITICAL`→`INCOMPLETE`, no `auto_merge`).

### F. Formalization & Knowledge Readiness
- **In:** verified outputs + policy. **Out:** target (`research-doc`|`structured-knowledge`|`executable-predicate`|`witness-fixture`|`internal-only`|`impl-spec`|`release-candidate`|`WITHHELD`|`BLOCKED`).
- **Readiness:** completeness != publication; `WITHHELD`/`internal-only` private; missing Owner/authority pin blocks unit.

### G. Implementation (Skip in `research-only`)
- **In:** formalized specs. **Out:** code/artifact commits.
- **Readiness:** reuse [`ship.md`](ship.md) (`check-wave -Partition`, `-CheckDirtyScope`, `-ProtectedPaths`, `SHARED_DISJOINT_WRITES`/`ISOLATED_WRITES`/`SEQUENTIAL`, `Context Packet`+1L `context_hint:`, `verify-run`/`verify-check`, `diff-scope`, `mechanical-check`, `symbol-check`, `context-cache`, `precommit`), [`references/context-routing.md`](references/context-routing.md) (`repo-evidence` only, [gates](references/research-ship-gates.md) §2), + [`../review-loop/strategy.md`](../review-loop/strategy.md). In `SHARED_DISJOINT_WRITES`, no worker Git mutation (ownership != OS isolation; safe ordinary tasks stay, escalate→`ISOLATED_WRITES`/`SEQUENTIAL` if per-worker attribution missing); Parent checks wave scope (`mechanical-check -AllowedPaths`) vs per-worker (`-WaveSpecs`+`-WorkerChanges` host/changeset attribution; never `UNVERIFIED_COMBINED_ONLY`) pre-commit + post-integration `verify-run`/review, then recomputes deps/`check-freshness`/dirty scope.
- **Failure / Recovery:** `WAVE_CONFLICT`/`WAVE_SEQUENTIAL`/`malformed_wave_output` → sequential (`WAVE_BASE_MISMATCH` → `BLOCKED`/re-scope); Tier-1/2 breaker → `strategy.md`.

### H. Technical Verification & Independent Review / Editorial Gates
- **In:** diff/evidence/policy. **Out:** separate **Research** (sources/attribution/conditions/disputes) & **Engineering** (tests/security/runtime) verdicts + Editorial (`b3-reviewer.md`, specialists, digest gate, [gates](references/research-ship-gates.md)).
- **Failure / Recovery:** passing tests never override source failure; unauthorized reviewer, bad digest, or `CONFIRMED` blocker → fix pre-PR.

### I. PR Lifecycle (When publishing via PR)
- **In:** green verified branch. **Out:** 1 up-to-date PR vs target (`main`, `develop`, `release/*`, `feature/*`, stacked).
- **Readiness:** reconcile `origin/<target>`; final checks; 0 blockers; reuse open PR (`gh pr list --head <branch>`); push; create/update PR; fix CI/review blockers.

### J. Merge Eligibility Evaluation
- **In:** `-PrNumber <N>`, `-LedgerPath`, governance, trusted `default_branch` `.b3/research-policy.json`.
- **Readiness:** `b3-guard merge-policy-check` ([gates](references/research-ship-gates.md)). Default `auto_merge: disabled`/offline → `PR_READY`/`LOCAL_ELIGIBLE_ONLY` (`exit 2`) or `BLOCKED` (`exit 1`); `UNKNOWN`/`SINGLE_AGENT_LIMIT` block `auto_merge`. Require live CI, non-author head-SHA review, branch protection/CODEOWNERS (no write-access inference).

### K. Authorized Auto-Merge & Post-Merge Verification
- **In:** `MERGE_AUTHORIZED` (`exit 0`).
- **Readiness:** merge; `merge-policy-check -PostMerge -PrNumber <N> -MainRef origin/<target>`; reconcile artifacts/coverage/authority + `evidence-check`. Report `MERGED_VERIFIED` (`pr_status=PR_MERGED`, `runtime_served=NOT_VERIFIED`, `deployed=NOT_VERIFIED` unless verified).

## Parallel Research & Subagent Naming

- Evaluate ready units per [`references/dispatch-naming.md`](references/dispatch-naming.md) via `b3-guard check-wave -Partition` (`-WaveReads`, `-ProtectedPaths`, `-IgnoreDirtyPaths`, `-CheckDirtyScope`, `-ExpectedBaseSha`; no `.` root/symlink escapes). Act strictly on `wave|N|PARALLEL|...` or `SEQUENTIAL` (never infer from `WAVE_OK`/`WAVE_PARTITIONED`; malformed→`malformed_wave_output`/`BLOCKED`): `SHARED_READ_ONLY` (`TaskId=none`/`[]`+`-WaveReads`, no temp/dummy writes/worktrees/commits, findings→Parent, mixed-wave RW check); `SHARED_DISJOINT_WRITES` (existing worktree, disjoint writes + wave `-AllowedPaths` vs per-worker `-WaveSpecs`+`-WorkerChanges` check, never `UNVERIFIED_COMBINED_ONLY`); `ISOLATED_WRITES` (`check-worktree -RequireIsolated ...`, see A); else `SEQUENTIAL`. Post-wave, recompute deps/`check-freshness`/dirty scope/`check-wave -Partition`. Isolate blocked/failed units (`continue independent eligible units`), serialize shared ledgers/manifests/authority pins via single-writer Parent, record `last_wave:` (`dispatch=PARALLEL|SEQUENTIAL ...`).
- Aliases: `b3-research-<slug>`, `b3-impl-<task-id>`, `b3-reviewer`/`b3-fixer`/specialists if supported; store+resume by host ID (never fail if omitted).
