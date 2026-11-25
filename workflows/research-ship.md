# Research Ship Autonomous Workflow

End-to-end research-first delivery complementing [`ship.md`](ship.md) without duplicating its build engine. Do not embed product domain policy; read product profiles dynamically.

## Core Invariants & State Boundaries

- **Separated truth states:** `RESEARCHED != VERIFIED != IMPLEMENTED != RELEASED`; `PR_MERGED != RUNTIME_SERVED != DEPLOYED`.
- **Fail closed:** missing source evidence, Owner decision, stale receipt/manifest, tool failure, or unmet gate → `INCOMPLETE` / `FAIL` / `BLOCKED`, never `PASS` or `PR_READY`.
- **No fabrication:** never invent passages, editions, citations, witness outputs, Owner decisions, editorial approvals, or test passes.
- **No automatic human gate override:** follow product policy literally (use registered AI editorial review when authorized; never add extra human gates or bypass policy).
- **Unit isolation on domain blocks:** if unit `U00k` hits an unresolved domain/Owner decision, mark `U00k` `blocked` and continue independent eligible units.

## Modes

- `status [<run_id>|--all]` (read-only): `b3-guard.{ps1,sh} list-runs -Namespace research-ship` / `resolve-run` + summarize `{RUN_DIR}/progress.md`. Zero edits.
- `resume [<run_id>]`: load [`references/research-ship-resume.md`](references/research-ship-resume.md), reconcile Git + `evidence-check`, continue next eligible unit (never restart completed verified units after `/compact`).
- `research-only` | `research+implement` | `research+governed-release` | `existing-plan`: create/reuse `{RUN_DIR}` (`.b3/research-ship/runs/<run_id>/`) and run phases A–K.

## Lifecycle (Phases A–K)

Load [templates](references/research-ship-templates.md) on creation only; [gates](references/research-ship-gates.md) at E/H/I/J/K only; [context-routing](references/context-routing.md) on demand for repo exploration/Phase G (`repo-evidence` only; see [gates](references/research-ship-gates.md) §2).

### A. Preflight
- **In:** prompt/plan, repo state. **Out:** `B3_HOME`, `PRODUCT_ROOT`, branch/HEAD, open PR check (`gh pr list --head <branch>`), optional `.b3/research-profile.md` & `.b3/research-policy.json`, protected/single-writer paths, `{RUN_DIR}`.
- **Readiness:** `b3-guard check-worktree`; `b3-guard new-run -Namespace research-ship -Slug <slug>` (unless resuming); preserve existing `research/`, decisions, historical evidence, `initial_dirty_paths`.
- **Failure / Recovery:** missing `B3_HOME`, invalid worktree, or dirty overlap on targets → `BLOCKED` (never reset user work).

### B. Research Planning
- **In:** request + preflight. **Out:** bounded units `U001..U00N` (`research-plan.md`, or inline in `progress.md` for 1-unit queries): question, current knowledge, missing evidence, required sources, schools/domains, deps, ACs, verification, implications.
- **Readiness:** disjoint `owned_files`/`write_paths`, single-writer designation for shared ledgers/manifests/`evidence-index.md`/authority pins, ready for automatic wave scheduling ([dispatch](references/dispatch-naming.md)).
- **Failure / Recovery:** ambiguous domain decision → split blocked unit (`continue independent eligible units`) or `BLOCKED`; oversized campaign → partition cohesive units.

### C. Source Discovery & Provenance
- **In:** unit specs. **Out:** `evidence-index.md` + SHA-256 manifest `{RUN_DIR}/evidence/sources.manifest` (`b3-guard evidence-check -WriteManifest`).
- **Readiness:** evidence-index-first retrieval (refs + digests); classify every claim: `primary` | `secondary-scholarly` | `repo-evidence` | `prior-verified` | `unverified` | `conflicting`; keep attribution, conditions, uncertainty.
- **Failure / Recovery:** unavailable source → `unverified`/`EVIDENCE_MISSING` (`exit 1`); re-scope or mark unit `incomplete`/`blocked` without guessing.

### D. Cross-Source Analysis
- **In:** indexed sources. **Out:** unit notes comparing agreement, contradictions, missing conditions, school differences, unsupported generalizations, terminology ambiguity, context.
- **Readiness:** genuine disagreements remain `UNRESOLVED` / `DISPUTED` (never force consensus).
- **Failure / Recovery:** unsupported predicate or missing operand → `UNRESOLVED`, block formalization.

### E. Independent Evidence Verification
- **In:** unit claims + `evidence-index.md` + `sources.manifest`. **Out:** verdict (`VERIFIED` | `DISPUTED` | `INCOMPLETE`).
- **Readiness:** for non-trivial/high-risk evidence, dispatch isolated read-only verification subagents ([gates](references/research-ship-gates.md)) with compact refs + fingerprints (independent units concurrently via `check-wave -Partition` on read-only evidence & disjoint verdicts); check fidelity, provenance, conditions, contradictions, inferences.
- **Failure / Recovery:** `EVIDENCE_STALE` (`exit 2`) or `DISPUTED` → re-verify or return to C/D; no isolation → `SINGLE_AGENT_LIMIT` hat-change (cannot emit `PASS`/`VERIFIED`/`MERGE_AUTHORIZED` on `HIGH`/`CRITICAL` → `INCOMPLETE`; blocks `auto_merge`).

### F. Formalization & Knowledge Readiness
- **In:** verified outputs + policy. **Out:** target per unit (`research-doc` | `structured-knowledge` | `executable-predicate` | `witness-fixture` | `internal-only` | `impl-spec` | `release-candidate` | `WITHHELD` | `BLOCKED`).
- **Readiness:** completeness != publication; `WITHHELD`/`internal-only` stays non-public; missing Owner/authority pin blocks only affected unit.

### G. Implementation (Skip in `research-only`)
- **In:** formalized specs. **Out:** code/structured artifact commits.
- **Readiness:** reuse [`ship.md`](ship.md) (`check-wave -Partition`, `Context Packet`+1L `context_hint:`, `verify-run`/`verify-check`, `diff-scope`, `mechanical-check`, `symbol-check`, `context-cache`, `precommit`), [`references/context-routing.md`](references/context-routing.md) (`repo-evidence` only per [gates](references/research-ship-gates.md) §2), + [`../review-loop/strategy.md`](../review-loop/strategy.md). Single-writer ledgers/manifests/authority pins + sequential commits + post-integration `verify-run`.
- **Failure / Recovery:** `WAVE_CONFLICT`/`WAVE_SEQUENTIAL` → sequential (`WAVE_BASE_MISMATCH` → `BLOCKED`/re-scope); Tier-1/2 breaker → `strategy.md`.

### H. Technical Verification & Independent Review / Editorial Gates
- **In:** diff/evidence/policy. **Out:** separate **Research** (`sources/attribution/conditions/disputes`) and **Engineering** (`tests/security/runtime`) verdicts + Editorial Review if required (`b3-reviewer.md` + specialists + digest-bound editorial gate per [gates](references/research-ship-gates.md)).
- **Failure / Recovery:** passing tests never override source failure; unauthorized reviewer, invalid digest, or `CONFIRMED` blocker → fix & revalidate before PR.

### I. PR Lifecycle (When publishing/delivering via PR)
- **In:** green verified branch. **Out:** single up-to-date PR against target (`main`, `develop`, `release/*`, `feature/*`, stacked parent).
- **Readiness:** reconcile `origin/<target>`; final checks; 0 blockers; reuse open PR (`gh pr list --head <branch>`); push; create/update PR; collect CI/review evidence; fix blockers & revalidate.

### J. Merge Eligibility Evaluation
- **In:** `-PrNumber <N>`, `-LedgerPath`, governance, trusted `default_branch` `.b3/research-policy.json`.
- **Readiness:** `b3-guard merge-policy-check` ([gates](references/research-ship-gates.md)). Default `auto_merge: disabled`/offline → stop **`PR_READY`** / **`LOCAL_ELIGIBLE_ONLY`** (`exit 2`) or **`BLOCKED`** (`exit 1`); `UNKNOWN`/`SINGLE_AGENT_LIMIT` block `auto_merge`. Never infer permission from write access or feature-branch policy; require live CI, non-author head-SHA review, branch protection/CODEOWNERS.

### K. Authorized Auto-Merge & Post-Merge Verification
- **In:** `MERGE_AUTHORIZED` (`exit 0`).
- **Readiness:** merge via GitHub; run `b3-guard merge-policy-check -PostMerge -PrNumber <N> -MainRef origin/<target>`; reconcile artifacts/coverage/authority; re-run `evidence-check`. Report `MERGED_VERIFIED` (`pr_status=PR_MERGED`, `runtime_served=NOT_VERIFIED`, `deployed=NOT_VERIFIED` unless separately verified).

## Parallel Research & Subagent Naming

- Evaluate ready units automatically per [`references/dispatch-naming.md`](references/dispatch-naming.md) via `b3-guard check-wave -Partition -WaveReads -MaxConcurrency -ExpectedBaseSha`: `WAVE_OK`/`WAVE_PARTITIONED` → launch disjoint wave 1 in parallel (read-only `sources.manifest`/`evidence-index.md`, disjoint outputs); `WAVE_SEQUENTIAL`/`WAVE_CONFLICT`/`no_host_isolation` → sequential fallback; `WAVE_BASE_MISMATCH` → `BLOCKED`/re-scope. Isolate blocked/failed units (`continue independent eligible units`), serialize shared ledgers/manifests/authority pins via single Parent writer, and record `last_wave:` (`dispatch=PARALLEL|SEQUENTIAL ...`).
- Logical aliases: lowercase `b3-research-<slug>`, `b3-impl-<task-id>`, canonical `b3-reviewer`/`b3-fixer`/specialists when host supports custom names; store host-returned IDs separately and resume by ID. Never fail dispatch if host omits custom names.
