# Ship & Review Visual Guide

Visual architecture, execution flow, and context-optimization reference for adaptive dispatch, `/b3-ship`, `/b3-review-loop`, standalone `/b3-review`, the shared merge-policy gate, and checkpoints (the full Phases A–K `/b3-research-ship` procedure lives in [`../workflows/research-ship.md`](../workflows/research-ship.md)).

> [!NOTE]
> This guide is human-facing documentation (`0` runtime LLM tokens). Canonical agent procedures stay in [`../workflows/ship.md`](../workflows/ship.md), [`../workflows/research-ship.md`](../workflows/research-ship.md), [`../workflows/references/dispatch-naming.md`](../workflows/references/dispatch-naming.md), [`../review-loop/strategy.md`](../review-loop/strategy.md), and [`../skills/engineering/code-review/SKILL.md`](../skills/engineering/code-review/SKILL.md).

---

## Diagram C — Adaptive Dispatch Decision Tree

**Task Size** and **Risk Level** are independent dimensions ([`../workflows/references/dispatch-naming.md`](../workflows/references/dispatch-naming.md), [`../review-loop/strategy.md`](../review-loop/strategy.md)): size and dependencies govern execution strategy and partitioning, while risk independently governs verification and specialist review depth.

```mermaid
flowchart TD
    Intake["Task Intake (Scope / Unit Readiness)"] --> SizeAxis["Independent Dimension 1: Task Size (XS | S | M | L | XL | XXL)"]
    Intake --> RiskAxis["Independent Dimension 2: Risk Level (LOW | MEDIUM | HIGH | CRITICAL - never inferred from LOC alone)"]

    SizeAxis --> FastCheck{"1-unit XS + inline AND implementation unset/auto or == main?"}
    FastCheck -->|"Yes"| InlineMain["Inline on main (no subagent / no DAG overhead)"]
    FastCheck -->|"No (>=2 ready units or >=S / notes / detailed / custom model)"| DepAnal{"2+ ready units?"}
    DepAnal -->|"No (1 ready unit)"| SeqMode["SEQUENTIAL (single b3-impl-t00N or serialized chain)"]
    DepAnal -->|"Yes"| WavePart["Dependency & Ownership Analysis: b3 guard check-wave --partition"]

    WavePart -->|"WAVE_BASE_MISMATCH"| BaseBlocked["BLOCKED (fail closed on base SHA drift)"]
    WavePart -->|"Read-only units (TaskId=none / [])"| SharedRO["SHARED_READ_ONLY (parallel read-only analysis / review)"]
    WavePart -->|"Disjoint writes + safe build/test"| SharedDW["SHARED_DISJOINT_WRITES (parallel disjoint edits, Parent integrates)"]
    WavePart -->|"High-risk / build side-effects"| IsoW["ISOLATED_WRITES (check-worktree --require-isolated)"]
    WavePart -->|"Write/RW/dirty conflict, missing isolation, or malformed"| SeqMode

    InlineMain --> RiskGate["Downstream Risk-Based Verification & Independent Review"]
    SharedRO --> RiskGate
    SharedDW --> RiskGate
    IsoW --> RiskGate
    SeqMode --> RiskGate
    RiskAxis -->|"Governs review & verification depth independently of Size"| RiskGate

    RiskGate -->|"LOW"| RiskLow["LOW: 0-tok checks + 1 fresh b3-reviewer"]
    RiskGate -->|"MEDIUM"| RiskMed["MEDIUM: b3-reviewer + triggered specialist"]
    RiskGate -->|"HIGH"| RiskHigh["HIGH: b3-reviewer + specialists + contract/dep review"]
    RiskGate -->|"CRITICAL"| RiskCrit["CRITICAL: deep review + mandatory specialists (no waiver) + cross-boundary verify-run"]
```

---

## 1. `/b3-ship` End-to-End Lifecycle (4-Mode Waves, Ownership & Merge Gates)

Core 8-step flow: `Preflight → Plan → Scope → Build → Verify → Review → Commit → Finalize` (plus optional provider-neutral merge gate when invoked under `/b3-research-ship` or governed PR workflows).

### Diagram D — Full B3 Ship Lifecycle

```mermaid
flowchart TD
    Entry["Host Entrypoint (1-hop): Cursor / Codex / Claude / Antigravity"] --> Resolve{"Mode?"}
    Resolve -->|"status / --all"| StatusOut["b3 guard resolve-run or list-runs (.b3/ship)"]
    Resolve -->|"resume / unfinished run"| Resume["Scenario C: ship-resume.md (Git ancestry + verify-check)"]
    Resolve -->|"New requirement / plan"| NewRun["b3 guard new-run (.b3/ship/runs/run_id + CURRENT)"]

    NewRun --> PreFlight["Preflight: record initial_dirty_paths, DirtyDigests, baseline cmds (lazy at run_base_sha only on Verify failure; else NOT_RUN(verify_green))"]
    PreFlight --> Plan["Plan (master-plan.md + clarification-gate.md >=96%): Invariants, AC1..ACn, Shared Contracts"]
    Plan --> ReadyCheck["Select Ready Tasks (pending + all depends_on completed; isolate only blocked ambiguous units)"]
    Resume --> ReadyCheck

    ReadyCheck --> Scope["Scope (JIT per task): Context Packet + optional detailed matrices + Readiness Gate"]
    Scope --> PreReview{"depth == detailed?"}
    PreReview -->|"Yes"| DesignRev["Pre-code Review (design-only, SHARED_READ_ONLY): architecture + security"]
    DesignRev -->|"CONFIRMED flaw (reset draft -> re-gate)"| Scope
    DesignRev -->|"Clean"| WaveCheck
    PreReview -->|"No (inline / notes)"| WaveCheck

    WaveCheck{"Dispatch path?"}
    WaveCheck -->|"1-unit XS + inline (impl unset/auto or == main)"| InlineTask["Fast-path: Inline on main (no subagent)"]
    WaveCheck -->|"1-task (>=S / notes / detailed / custom model)"| SeqImpl["Mode 4: SEQUENTIAL (1 b3-impl-t00N; save impl_agent)"]
    WaveCheck -->|"2+ ready tasks"| GuardWave["b3 guard check-wave --partition (--wave-reads, --protected-paths, --check-dirty-scope, --expected-base-sha)"]

    GuardWave -->|"WAVE_BASE_MISMATCH"| BlockedOut["BLOCKED (fail closed)"]
    GuardWave -->|"WAVE_SEQUENTIAL / conflict / malformed"| SeqImpl
    GuardWave -->|"WAVE_OK / WAVE_PARTITIONED (wave N PARALLEL)"| IsoMode{"Select Isolation Mode"}
    IsoMode -->|"none / [] readers"| ReadWave["Mode 1: SHARED_READ_ONLY (parallel read-only workers)"]
    IsoMode -->|"Disjoint low-risk writes"| SharedWave["Mode 2: SHARED_DISJOINT_WRITES (parallel disjoint writers)"]
    IsoMode -->|"High-risk / colliding side-effects"| IsoWave["Mode 3: ISOLATED_WRITES (check-worktree --require-isolated --peer-roots)"]

    ReadWave --> Hub["Single-Writer Parent Hub: merge discoveries, integrate wave"]
    SharedWave --> Hub
    IsoWave --> Hub
    InlineTask --> TaskVerify["Verify: b3 guard verify-run (writes b3-verify-v1 receipt; lazy baseline at run_base_sha only on failure)"]
    SeqImpl --> TaskVerify
    Hub --> TaskVerify

    TaskVerify --> Mech["0-Token Guard: diff-scope + mechanical-check + symbol-check (refactors)"]
    Mech -->|"Exit 2: safety_hits"| BlockedOut
    Mech -->|"Exit 2: VIOLATION / PARTIAL_ATTRIBUTION / MECHANICAL_FINDINGS / dangling_refs"| FixMech["Fix ownership, scope_creep, leftovers, obsoletes, or confirmed dangling_refs"]
    FixMech --> Mech
    Mech -->|"Exit 0: MECHANICAL_OK / advisory signals"| PostInt{"Parallel code wave?"}
    PostInt -->|"Yes"| CrossInt["Post-integration verify-run + cross-unit review"]
    PostInt -->|"No"| ReviewTier
    CrossInt --> ReviewTier["Review: inline+XS/S+LOW -> 1 b3-reviewer; else review-loop/strategy.md"]

    ReviewTier -->|"Blocking CONFIRMED"| LazySnap["b3 guard snapshot (pre_fix_object) -> Fix -> verify-run -> delta Review"]
    LazySnap --> ReviewTier
    ReviewTier -->|"HIGH/CRITICAL + SINGLE_AGENT_LIMIT"| IncOut["INCOMPLETE (blocks PASS & auto_merge)"]
    ReviewTier -->|"FAIL / STUCK"| FailStuck["FAIL | STUCK"]
    ReviewTier -->|"BLOCKED"| BlockedOut
    ReviewTier -->|"PASS (0 blockers + valid receipt)"| PreCommit["Single-Writer Commit: precommit --require-verify-receipt -> 1 git commit -> collapse approach"]

    PreCommit --> MoreTasks{"More ready tasks (recompute deps + check-freshness)?"}
    MoreTasks -->|"Yes"| ReadyCheck
    MoreTasks -->|"No"| FinalCond{"2+ completed tasks OR post-task edits?"}
    FinalCond -->|"Yes"| FinalVer["Finalize: e2e ACs + full checks + cumulative Cross-Cutting review (run_base_sha..HEAD) + final commit if edited"]
    FinalCond -->|"No (1 task, no post-task edits)"| FinalChecksOnly["Finalize: e2e ACs + full checks vs baseline_status (skip duplicate review)"]
    FinalVer --> MergeGate{"Governed PR / Research-Ship Gate?"}
    FinalChecksOnly --> MergeGate
    MergeGate -->|"No (standard /b3-ship)"| Outcome["Terminal Outcome: PASS | FAIL | STUCK | INCOMPLETE | BLOCKED"]
    MergeGate -->|"Yes"| PolicyCheck["b3 guard merge-policy-check (PR_READY / LOCAL_ELIGIBLE_ONLY / MERGE_AUTHORIZED / MERGE_BLOCKED / PROVIDER_UNAVAILABLE)"]
    PolicyCheck --> Outcome
```

---

## 2. Adaptive 4-Mode Wave Partitioning, Ownership Provenance & Merge Gate

Subagent logical aliases are described in [`../workflows/references/dispatch-naming.md`](../workflows/references/dispatch-naming.md) and are only requested when the host supports custom spawn names. Host-returned IDs remain authoritative for resume.

`b3 guard check-wave --partition` computes continuous `wave|N|...` sub-waves across four isolation modes (`SHARED_READ_ONLY`, `SHARED_DISJOINT_WRITES`, `ISOLATED_WRITES`, `SEQUENTIAL`). On partial ambiguity ([`../workflows/references/clarification-gate.md`](../workflows/references/clarification-gate.md)), only affected units are held while safe independent `SHARED_READ_ONLY` discovery and unblocked units continue without speculative edits. Subagents never talk directly to each other and never edit `read_only_deps`, `--protected-paths`, or `.b3/` state. Parent acts as the sole Hub, verifies per-worker ownership provenance (`CALLER_ATTRIBUTED` via `--worker-changes` or Git-proven `VERIFIED_PER_WORKER` via `--worker-roots`), resumes the owning `impl_agent` on delta findings, and evaluates provider-neutral `merge-policy-check` when governed merge gates apply.

```mermaid
sequenceDiagram
    participant P as Parent Orchestrator
    participant G as b3 guard CLI (0 tok)
    participant W2 as b3-impl-t002 (logical alias)
    participant W3 as b3-impl-t003 (logical alias)
    participant R as Fresh Independent Reviewer

    P->>G: check-wave --partition (--wave-specs, --wave-reads, --protected-paths, --check-dirty-scope, --expected-base-sha)
    G-->>P: WAVE_OK or WAVE_PARTITIONED (wave 1 PARALLEL, adaptive concurrency)
    Note over P,G: Choose SHARED_READ_ONLY, SHARED_DISJOINT_WRITES, or ISOLATED_WRITES (check-worktree --require-isolated --peer-roots)

    par Launch T002
        P->>W2: Brief (owned paths, verbatim contract, 1L context_hint, scoped verify-run)
    and Launch T003
        P->>W3: Brief (owned paths, verbatim contract, 1L context_hint, scoped verify-run)
    end
    Note over P: Store host-returned impl_agent IDs in progress.md

    W2-->>P: <=25 lines (files_changed, cmds, discoveries, change_requests)
    W3-->>P: <=25 lines (files_changed, cmds, discoveries, change_requests)

    P->>G: verify-run on worker/integrated work (--relevant-paths -> b3-verify-v1 receipts)
    G-->>P: VERIFY_PASS (b3-verify-v1 receipt; post-integration verify-run on parallel code waves)

    P->>G: diff-scope + mechanical-check (--wave-specs, --worker-changes or --worker-roots, --protected-paths, --dirty-digests)
    G-->>P: exit 0 MECHANICAL_OK (CALLER_ATTRIBUTED / VERIFIED_PER_WORKER, or UNVERIFIED_COMBINED_ONLY for ordinary disjoint wave) vs exit 2 (PARTIAL_ATTRIBUTION / VIOLATION)

    P->>R: Independent review (base_sha, review_files, cross-unit context, active findings only)
    R-->>P: <=25 lines (Verdict: BLOCKING_FINDINGS - R001 in api/orders.ts)

    P->>G: Lazy snapshot (capture pre_fix_object only because blocking findings exist)
    G-->>P: pre_fix_object SHA

    P->>W2: Resume impl_agent_2 with R001 delta only (warm prompt cache)
    W2-->>P: <=20 lines (R001 bug-class sweep + fix applied)

    P->>G: verify-run (updated b3-verify-v1 receipt before guard & precommit)
    G-->>P: VERIFY_PASS (exit 0)

    P->>G: diff-scope --prev-sha pre_fix_object + mechanical-check
    G-->>P: delta_files=api/orders.ts and MECHANICAL_OK

    P->>R: Fresh Reviewer Pass 2 (delta_files + callers + residue)
    R-->>P: <=25 lines (Verdict: NO_BLOCKING_FINDINGS)

    P->>G: precommit --require-verify-receipt (T002 allowed-paths + expected-cmd) then commit T002
    P->>G: precommit --require-verify-receipt (T003 allowed-paths + expected-cmd) then commit T003

    opt Governed PR or /b3-research-ship merge gate
        P->>G: merge-policy-check (trunk .b3/research-policy.json, mode=local or optional --pr-number b3 pr verify)
        G-->>P: PR_READY / LOCAL_ELIGIBLE_ONLY / MERGE_AUTHORIZED / MERGE_BLOCKED / PROVIDER_UNAVAILABLE
    end
```

---

## 3. `/b3-review-loop` Convergence & 2-Tier Circuit Breaker

[`../review-loop/strategy.md`](../review-loop/strategy.md) is self-sufficient at runtime (skipping `spec.md`, `sizing.md`, and `models.md` on normal runs to avoid loading large reference docs per invocation).

### Diagram E — Review Loop & Hierarchical Review

```mermaid
flowchart TD
    Start["/b3-review-loop or /b3-ship Review"] --> Scope["Guard (0-Token CLI): diff-scope + mechanical-check + symbol-check (refactors)"]
    Scope -->|"EMPTY_DIFF (exit 2)"| Incomplete["UNKNOWN / INCOMPLETE"]
    Scope -->|"Exit 2: safety_hits"| BlockedGuard["BLOCKED (terminal stop)"]
    Scope -->|"Exit 2: MECHANICAL_FINDINGS / SYMBOL_FINDINGS (dangling_refs)"| FixMech["Fix scope_creep, leftovers, obsoletes, or confirmed dangling_refs"]
    FixMech --> Scope
    Scope -->|"NOISE_ONLY or CLEAN_AFTER_FIX"| FastVerify["Verify: b3 guard verify-run / verify-check (CLEAN_AFTER_FIX -> delta_files check)"]
    FastVerify -->|"Green"| PassFast["PASS (0 LLM review tokens)"]
    FastVerify -->|"Red"| FailFast["FAIL"]

    Scope -->|"XS / S / M (max 5 iter, incl. Exit 0 advisory signals)"| RiskRoute{"Decoupled risk_level specialist routing"}
    RiskRoute -->|"LOW"| RevLow["Fresh b3-reviewer (0-tok checks + 1 reviewer)"]
    RiskRoute -->|"MEDIUM"| RevMed["b3-reviewer + triggered specialist"]
    RiskRoute -->|"HIGH"| RevHigh["b3-reviewer + specialists + contract/dep review"]
    RiskRoute -->|"CRITICAL"| RevCrit["Deep review + mandatory specialists (no waiver) + cross-boundary verify-run"]

    RevLow --> Merge["Orchestrator merges & classifies findings (OPEN | FIXED | REJECTED | ACCEPTED | SPECULATIVE | UNKNOWN)"]
    RevMed --> Merge
    RevHigh --> Merge
    RevCrit --> Merge

    Merge --> Gate{"Gate: OPEN == 0 AND VERIFY_VALID AND risk evidence met?"}
    Gate -->|"HIGH/CRITICAL + SINGLE_AGENT_LIMIT"| SingleLimit["UNKNOWN / INCOMPLETE (blocks PASS & auto_merge)"]
    Gate -->|"Red verify-check / failed check"| FailGate["FAIL"]
    Gate -->|"Missing/stale receipt or tool fail"| Incomplete
    Gate -->|"Yes"| PassLoop["PASS"]
    Gate -->|"No (blocking OPEN > 0)"| Breaker{"2-Tier Circuit Breaker?"}

    Breaker -->|"Tier 1: same finding survives 2 rounds"| ResetSubagent["Tier 1: rewrite brief or spawn fresh b3-fixer (drop impl_agent)"]
    Breaker -->|"Tier 2: same bug_class 2 rounds"| Redesign["Tier 2: design flaw -> stop patching, return to Scope / Design"]
    Breaker -->|"Flat/rising blockers, stagnation, or max 5 cap"| Stuck["STUCK / INCOMPLETE (or FAIL if blockers remain)"]
    Breaker -->|"Converging"| Snap["b3 guard snapshot (prev_sha) + update state.md"]

    ResetSubagent --> Snap
    Snap --> Fix["Fix: impl_agent or b3-fixer (bug-class sweep; disjoint via check-wave --partition; <=20L) + verify-run"]
    Fix --> LoopBack["Loop to diff-scope --prev-sha prev_sha"]
    LoopBack --> Scope

    Scope -->|"L / XL / XXL"| L0["L0: b3 guard review-inventory + review-ledger --action init (L/XL<=12, XXL<=24 passes)"]
    L0 -->|"PARTITION_INCOMPLETE (exit 2)"| LBlocked["INCOMPLETE / BLOCKED"]
    L0 -->|"Cohesive units partitioned"| L1{"L1: l1_specialists != none?"}
    L1 -->|"Yes"| L1Run["L1: SHARED_READ_ONLY contracts/arch/security/perf review"]
    L1 -->|"No (record l1_skip_rationale)"| L2
    L1Run --> L2["L2: Bounded per-unit loops (<=3 iter/unit, adaptive concurrency, unit risk specialists, verify-run on HIGH/CRITICAL code, single-writer ledger update)"]
    L2 --> L3["L3: Cross-unit integration review (<=2 iter, SHARED_READ_ONLY + post-integration verify-run after parallel code waves)"]
    L3 --> L4["L4: b3 guard review-ledger --action check"]
    L4 -->|"LEDGER_GATE_PASS + green checks + valid independence"| PassHier["PASS"]
    L4 -->|"HIGH/CRITICAL + SINGLE_AGENT_LIMIT"| SingleLimit
    L4 -->|"Red check"| FailHier["FAIL"]
    L4 -->|"Stale/missing/tamper/bad CRITICAL waiver/cap"| LBlocked
```

---

## 4. Standalone `/b3-review` — 3-Mode Flow (Local, GitHub PR & Safe Posting)

Standalone `/b3-review` ([`../commands/b3-review.md`](../commands/b3-review.md), [`../skills/engineering/code-review/SKILL.md`](../skills/engineering/code-review/SKILL.md)) routes into 3 explicit modes, renders every chat report and GitHub PR summary with the shared [`../skills/engineering/code-review/references/review-template.md`](../skills/engineering/code-review/references/review-template.md) (`CRITICAL` | `HIGH` | `MEDIUM` | `LOW`), and delegates authorized `--post` publication to [`../skills/engineering/pr-feedback/SKILL.md`](../skills/engineering/pr-feedback/SKILL.md) + `b3 pr` (`0` extra bytes on local reviews).

```mermaid
flowchart TD
    Inv["/b3-review [target]"] --> Mode{"Target Mode?"}

    Mode -->|"Local (default)"| AutoBase["b3 guard diff-scope (auto base: dirty WT -> HEAD; clean branch -> merge-base)"]
    AutoBase --> LocalMech["b3 guard mechanical-check (+ symbol-check on refactors) + verify-check on receipts"]
    LocalMech --> LocalNoise{"size_class == NOISE_ONLY?"}
    LocalNoise -->|"Yes + green checks"| LocalPass["PASS (skip LLM review)"]
    LocalNoise -->|"No"| ReviewPass["1 Delta-First Review Pass (contracts, ACs, correctness, security, perf, residue, tests)"]

    Mode -->|"GitHub PR (#id / URL)"| LoadRef["Open references/github-pr-review.md"]
    LoadRef --> PrMeta["gh pr view --json ... --jq ... (filtered context + ticket ACs + failed checks)"]
    PrMeta --> FilterNoise["Filter out lockfiles / minified / snapshots / generated"]
    FilterNoise --> FetchDiff["Local clone: 2-step fetch base + PR head + b3 guard --target-ref FETCH_HEAD (+ symbol-check); Remote: gh api"]
    FetchDiff --> ReviewPass

    ReviewPass --> ChatReport["Compact findings report in chat (CONFIRMED vs SPECULATIVE + checked/skipped dimensions)"]
    ChatReport --> PostGate{"User requested or authorized --post to GitHub PR?"}
    PostGate -->|"No"| Done["Done (read-only review)"]
    PostGate -->|"Yes"| SignalGate["Delegate to pr-feedback + b3 pr comment (CONFIRMED findings only; COMMENT default)"]
    SignalGate --> PostType{"Publication mode?"}
    PostType -->|"summary / both / --draft"| SummaryCmd["b3 pr comment (SHA-fresh review body via stdin JSON + remote object verification)"]
    PostType -->|"inline"| InlineCmd["b3 pr comment (diff-hunk validated inline threads on head_sha)"]
```

---

## 5. Run-Scoped Checkpoints & Context Budget Architecture

Checkpoints are isolated per run under `.b3/ship/runs/<run_id>/` (and `.b3/research-ship/runs/<run_id>/`, gitignored) and addressed via a 1-line plain-text `CURRENT` pointer, so normal runs never scan sibling history. `diff-scope` (`test_checkpoint_path` in [`../src/fs.rs`](../src/fs.rs)) excludes `.b3/{ship,research-ship,autodev}/`, so standalone `/b3-verify` receipts (`.b3/ship/verify/`) and standalone `/b3-review-loop` state (`.b3/ship/review-loop/<slug>/`) stay out of diffs without affecting `CURRENT` or `resolve-run`. Canonical PR feedback state and PID locks live under `<git-common-dir>/b3/pr-feedback/` (shared across linked worktrees), while `.b3/pr-feedback/` is gitignored local scratch only.

```mermaid
flowchart LR
    Cur[".b3/ship/CURRENT (1 line: run_id, ~45 B)"] --> RunDir[".b3/ship/runs/run_id/"]
    RunDir --> MP["master-plan.md (Invariants, Shared contracts, Tasks)"]
    RunDir --> PR["progress.md (run_status, SHAs, impl_agent, collapsed approaches)"]
    RunDir --> FN["findings.md (Sole monotonic R001.. log)"]
    RunDir --> AP["approach/T00N.md (optional: notes / detailed)"]
    RunDir --> EV["evidence/*.verify (b3-verify-v1 receipt + optional .log)"]
    RunDir --> LG["logs/ (optional: long failing test logs)"]

    StandaloneVer[".b3/ship/verify/*.verify (standalone /b3-verify receipts)"] -.->|"Excluded from diff-scope, tree_hash, and resolve-run"| Cur
    StandaloneRL[".b3/ship/review-loop/slug/state.md (standalone loop state)"] -.->|"Excluded from diff-scope, tree_hash, and resolve-run"| Cur
    PrFb["git-common-dir/b3/pr-feedback/ (canonical PR state & PID locks)"] -.->|"Shared across linked worktrees (.b3/pr-feedback/ is gitignored scratch only)"| Cur
    Prune["b3 guard prune"] -.->|"Keeps newest 10 PASS; never deletes CURRENT or non-PASS"| RunDir
```

### Static Context Budgets (`b3 context measure --strict`)

All byte caps and `(bytes + 2) / 4` token estimates are measured in **canonical LF UTF-8 bytes** (identical across Windows PowerShell, Git Bash, macOS, and Linux) and enforced by `b3 context measure --strict` (canonical thresholds live in [`../src/context.rs`](../src/context.rs)).

---

## 6. Cost-Preserving Quality Model Tiering (4-Tier Routing)

The system separates **Deep reasoning**, **Standard execution**, **Fast surgical execution**, and **Deterministic (0-token) verification** in a host-neutral way — see [`../review-loop/models.md`](../review-loop/models.md) for the canonical 4-tier routing table, guardrails, and **Cost-Aware Escalation** rules.

---

## Related canonical documents

- Core `/b3-ship` & `/b3-research-ship` procedures & PR template: [`../workflows/ship.md`](../workflows/ship.md), [`../workflows/research-ship.md`](../workflows/research-ship.md), [`../workflows/references/clarification-gate.md`](../workflows/references/clarification-gate.md), [`../workflows/references/pr-template.md`](../workflows/references/pr-template.md)
- Core `/b3-review-loop` procedure: [`../review-loop/strategy.md`](../review-loop/strategy.md)
- Core `/b3-review` & PR feedback skills: [`../skills/engineering/code-review/SKILL.md`](../skills/engineering/code-review/SKILL.md), [`../skills/engineering/pr-feedback/SKILL.md`](../skills/engineering/pr-feedback/SKILL.md), [`../skills/engineering/code-review/references/review-template.md`](../skills/engineering/code-review/references/review-template.md), [`../skills/engineering/code-review/references/github-pr-review.md`](../skills/engineering/code-review/references/github-pr-review.md)
- Deterministic CLI reference: [`../scripts/README.md`](../scripts/README.md)
- Architecture decisions: [`../research/decisions/decision-012-autodev-v2-hardening.md`](../research/decisions/decision-012-autodev-v2-hardening.md), [`../research/decisions/decision-013-host-neutral-multi-host-layout.md`](../research/decisions/decision-013-host-neutral-multi-host-layout.md), [`../research/decisions/decision-014-autodev-parallel-waves-and-mechanical-pass.md`](../research/decisions/decision-014-autodev-parallel-waves-and-mechanical-pass.md), [`../research/decisions/decision-015-evidence-gates-tripwires-and-context-budgets.md`](../research/decisions/decision-015-evidence-gates-tripwires-and-context-budgets.md), [`../research/decisions/decision-016-standalone-commands-quality-and-context.md`](../research/decisions/decision-016-standalone-commands-quality-and-context.md), [`../research/decisions/decision-017-global-cursor-integration.md`](../research/decisions/decision-017-global-cursor-integration.md), [`../research/decisions/decision-018-research-ship-workflow.md`](../research/decisions/decision-018-research-ship-workflow.md)
