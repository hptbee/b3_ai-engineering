# Research Ship Autonomous Workflow

End-to-end research-first delivery complementing [`ship.md`](ship.md) without duplicating its build engine. Do not embed product-specific domain policy here; read product profiles dynamically when present.

## Core Invariants & State Boundaries

- **Separated truth states:** `RESEARCHED != VERIFIED != IMPLEMENTED != RELEASED`; `PR_MERGED != RUNTIME_SERVED != DEPLOYED`.
- **Fail closed:** missing source evidence, missing Owner decision, stale receipt/manifest, tool failure, or unmet gate → `INCOMPLETE` / `FAIL` / `BLOCKED`, never `PASS` or `PR_READY`.
- **No fabrication:** never invent passages, editions, citations, witness outputs, Owner decisions, editorial approvals, or test passes.
- **No automatic human gate override:** follow product policy literally (when product policy authorizes registered AI editorial review, use it; never add extra human gates or bypass required policy).
- **Unit isolation on domain blocks:** if unit `U00k` is blocked by an unresolved domain/Owner decision, mark `U00k` `blocked` and continue independent eligible units.

## Modes

- `status [<run_id>|--all]` (read-only): `b3-guard.{ps1,sh} list-runs -Namespace research-ship` / `resolve-run` + summarize `{RUN_DIR}/progress.md`. Zero edits.
- `resume [<run_id>]`: load [`references/research-ship-resume.md`](references/research-ship-resume.md), reconcile Git + `evidence-check`, continue next eligible unit (never restart completed verified units after `/compact`).
- `research-only` | `research+implement` | `research+governed-release` | `existing-plan`: create/reuse `{RUN_DIR}` (`.b3/research-ship/runs/<run_id>/`) and execute applicable phases A–K.

## Lifecycle (Phases A–K)

Load [templates](references/research-ship-templates.md) only on creation; [gates](references/research-ship-gates.md) only at phases E/H/I/J/K; [context-routing](references/context-routing.md) on demand for repo exploration/Phase G (`repo-evidence` only; see [gates](references/research-ship-gates.md) §2).

### A. Preflight
- **In:** user prompt / plan path, repo state. **Out:** `B3_HOME`, `PRODUCT_ROOT`, branch/HEAD, existing PR check (`gh pr list --head <branch>`), optional `.b3/research-profile.md` & `.b3/research-policy.json`, protected/single-writer paths, `{RUN_DIR}`.
- **Readiness:** `b3-guard check-worktree`; `b3-guard new-run -Namespace research-ship -Slug <slug>` (unless resuming); preserve existing `research/`, decisions, historical evidence, and `initial_dirty_paths`.
- **Failure / Recovery:** missing `B3_HOME`, invalid worktree, or dirty overlap on target paths → `BLOCKED` (report; never reset/discard user work).

### B. Research Planning
- **In:** request + preflight context. **Out:** bounded units `U001..U00N` (`research-plan.md`, or inline inside `progress.md` for small 1-unit queries): question, current knowledge, missing evidence, required sources, schools/domains, deps, ACs, verification method, implementation/release implications.
- **Readiness:** disjoint `owned_files` / `write_paths`, single-writer designation for shared ledgers/manifests/authority files.
- **Failure / Recovery:** ambiguous product/domain decision → split out blocked unit or stop `BLOCKED`; oversized campaign → partition cohesive units.

### C. Source Discovery & Provenance
- **In:** unit specs. **Out:** `evidence-index.md` + SHA-256 manifest `{RUN_DIR}/evidence/sources.manifest` (`b3-guard evidence-check -WriteManifest -SourcePaths ... -ManifestPath ...`).
- **Readiness:** evidence-index-first retrieval (references + digests, not repeated full dumps); classify every claim: `primary` | `secondary-scholarly` | `repo-evidence` | `prior-verified` | `unverified` | `conflicting`; retain attribution, conditions, uncertainty.
- **Failure / Recovery:** unavailable source → `unverified` / `EVIDENCE_MISSING` (`exit 1`); re-scope or mark unit `incomplete`/`blocked` without guessing from memory.

### D. Cross-Source Analysis
- **In:** indexed sources. **Out:** unit analysis notes comparing agreement, contradictions, missing conditions, school differences, unsupported generalizations, terminology ambiguity, historical context.
- **Readiness:** genuine disagreements remain explicit `UNRESOLVED` / `DISPUTED` (never force artificial consensus).
- **Failure / Recovery:** unsupported predicate or missing operand → mark `UNRESOLVED` and block formalization.

### E. Independent Evidence Verification
- **In:** unit claims + `evidence-index.md` + `sources.manifest`. **Out:** verification verdict (`VERIFIED` | `DISPUTED` | `INCOMPLETE`).
- **Readiness:** for non-trivial/high-risk evidence, dispatch isolated read-only verification subagent ([gates](references/research-ship-gates.md)) with compact refs + fingerprints; check fidelity, provenance, conditions, contradiction handling, inferences.
- **Failure / Recovery:** `EVIDENCE_STALE` (`exit 2`) or `DISPUTED` → re-verify against updated source or return to C/D; no subagent isolation → log `SINGLE_AGENT_LIMIT` hat-change (cannot emit `PASS`/`VERIFIED`/`MERGE_AUTHORIZED` on `HIGH`/`CRITICAL` — cap `INCOMPLETE`, needs independent/human review; unconditionally blocks `auto_merge`).

### F. Formalization & Knowledge Readiness
- **In:** verified unit outputs + domain policy. **Out:** target classification per unit (`research-doc` | `structured-knowledge` | `executable-predicate` | `witness-fixture` | `internal-only` | `impl-spec` | `release-candidate` | `WITHHELD` | `BLOCKED`).
- **Readiness:** completeness never implies publication; `WITHHELD`/`internal-only` stays non-public; missing Owner/authority pin blocks only affected unit.

### G. Implementation (Skip in `research-only`)
- **In:** formalized specs. **Out:** code/structured artifact commits.
- **Readiness:** reuse [`ship.md`](ship.md) (`check-wave`, `Context Packet` + 1L `context_hint:`, `verify-run`/`verify-check`, `diff-scope`, `mechanical-check`, `symbol-check`, `context-cache`, `precommit`), on-demand [`references/context-routing.md`](references/context-routing.md) (`repo-evidence` only per [gates](references/research-ship-gates.md) §2), + [`../review-loop/strategy.md`](../review-loop/strategy.md). Enforce single-writer serialization on shared ledgers/manifests/authority pins.
- **Failure / Recovery:** `WAVE_CONFLICT` → degrade to sequential; Tier-1/2 review breaker → follow `strategy.md`.

### H. Technical Verification & Independent Review / Editorial Gates
- **In:** diff/evidence/policy. **Out:** separate **Research** (`sources/attribution/conditions/disputes`) and **Engineering** (`tests/security/runtime`) verdicts, plus product Editorial Review when policy requires it (`b3-reviewer.md` + specialists + digest-bound editorial gate per [gates](references/research-ship-gates.md)).
- **Failure / Recovery:** passing tests never override source failure; unauthorized reviewer, invalid digest, or `CONFIRMED` blocker → fix & revalidate before PR.

### I. PR Lifecycle (When publishing/delivering via PR)
- **In:** green verified branch. **Out:** single up-to-date PR against `main`.
- **Readiness:** reconcile `origin/main`; run final checks; verify 0 blocking findings; reuse existing PR if open (`gh pr list --head <branch>` — avoid duplicates); push branch; create/update PR; collect CI/review evidence; fix confirmed findings & revalidate.

### J. Merge Eligibility Evaluation
- **In:** PR state, CI status, review status, governance status, changed paths, `.b3/research-policy.json`.
- **Readiness:** run `b3-guard merge-policy-check` ([gates](references/research-ship-gates.md)). Default `auto_merge: disabled` → stop at **`PR_READY`** (`exit 2`) or **`BLOCKED`** (`exit 1`); `SINGLE_AGENT_LIMIT` unconditionally blocks `auto_merge`. Never infer merge permission from repo write access; respect branch protection, required checks, CODEOWNERS, and domain release authority.

### K. Authorized Auto-Merge & Post-Merge Verification
- **In:** `MERGE_AUTHORIZED` (`exit 0` from `merge-policy-check`).
- **Readiness:** merge via GitHub; confirm `PR == MERGED`; run `b3-guard merge-policy-check -PostMerge -PrState MERGED -MergedSha <sha> -MainRef origin/main`; reconcile affected artifacts/coverage/authority boundaries; verify evidence freshness (`evidence-check`). Report `MERGED_VERIFIED` with `runtime_served=NOT_VERIFIED` and `deployed=NOT_VERIFIED` unless separately verified.

## Parallel Research & Subagent Naming

- Launch parallel research subagents only after `b3-guard check-wave -WaveReads -ExpectedBaseSha` returns `WAVE_OK`, sharing read-only evidence paths and serializing shared ledgers/manifests.
- Logical aliases: prefer lowercase `b3-research-<slug>`, `b3-impl-<task-id>`, and canonical `b3-reviewer` / `b3-fixer` / specialists when the host supports custom spawn names; store host-returned IDs separately and resume by ID. Never fail dispatch if the host omits custom names.
