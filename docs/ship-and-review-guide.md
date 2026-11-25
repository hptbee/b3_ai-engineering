# Ship & Review Visual Guide

Architecture, execution flow, and context-optimization reference for `/b3-ship`, `/b3-research-ship`, `/b3-review-loop`, and standalone `/b3-review`.

> [!NOTE]
> This guide is human-facing documentation (`0` runtime LLM tokens). Canonical agent procedures stay in [`../workflows/ship.md`](../workflows/ship.md), [`../workflows/research-ship.md`](../workflows/research-ship.md), [`../review-loop/strategy.md`](../review-loop/strategy.md), and [`../skills/engineering/code-review/SKILL.md`](../skills/engineering/code-review/SKILL.md).

---

## 1. `/b3-ship` End-to-End Lifecycle (4-Mode Waves, Ownership & Merge Gates)

Core 7-step flow: `Preflight → Plan → [Scope → Build → Verify → Review → Commit] → Finalize` (plus optional provider-neutral merge gate when invoked under `/b3-research-ship` or governed PR workflows).

```mermaid
flowchart TD
    Entry["Host Entrypoint (1-hop): Cursor / Codex / Claude / Antigravity"] --> Resolve{"Mode?"}
    Resolve -->|"status / --all"| StatusOut["b3-guard resolve-run or list-runs (.b3/ship + .b3/autodev fallback)"]
    Resolve -->|"resume / unfinished run"| Resume["Scenario C: ship-resume.md (Git ancestry + verify-check)"]
    Resolve -->|"New requirement / plan"| NewRun["b3-guard new-run (.b3/ship/runs/run_id + CURRENT)"]

    NewRun --> PreFlight["Preflight: initial_dirty_paths + DirtyDigests + baseline checks"]
    PreFlight --> Plan["Plan (master-plan.md): Invariants, AC1..ACn, Verbatim Shared Contracts"]
    Plan --> ReadyCheck["Select Ready Tasks (pending + all depends_on completed)"]
    Resume --> ReadyCheck

    ReadyCheck --> Scope["Scope (JIT per task): Context Packet + optional detailed matrices + Gate"]
    Scope --> PreReview{"depth == detailed?"}
    PreReview -->|"Yes"| DesignRev["1-Pass Pre-code Review (design-only): architecture + security"]
    DesignRev -->|"CONFIRMED flaw"| Scope
    DesignRev -->|"Clean"| WaveCheck
    PreReview -->|"No (inline / notes)"| WaveCheck

    WaveCheck{"2+ ready tasks?"}
    WaveCheck -->|"Yes"| GuardWave["b3-guard check-wave -Partition (WaveReads, ProtectedPaths, CheckDirtyScope, MaxConcurrency 1..4)"]
    GuardWave -->|"WAVE_OK / WAVE_PARTITIONED (wave N PARALLEL)"| IsoMode{"Select Isolation Mode"}
    IsoMode -->|"none / [] readers"| ReadWave["Mode 1: SHARED_READ_ONLY (parallel read-only workers in shared WT)"]
    IsoMode -->|"Disjoint low-risk writes"| SharedWave["Mode 2: SHARED_DISJOINT_WRITES (parallel disjoint writers in shared WT)"]
    IsoMode -->|"High-risk / build side effects"| IsoWave["Mode 3: ISOLATED_WRITES (check-worktree -RequireIsolated -PeerRoots)"]
    GuardWave -->|"WAVE_SEQUENTIAL / WAVE_BASE_MISMATCH"| SeqImpl["Mode 4: SEQUENTIAL (1 b3-impl-t00N subagent; save impl_agent)"]
    WaveCheck -->|"No (1 task)"| SeqImpl

    ReadWave --> Hub["Parent Hub Relay: merge discoveries & change_requests + integrate"]
    SharedWave --> Hub
    IsoWave --> Hub
    SeqImpl --> TaskVerify["Verify: b3-guard verify-run (writes b3-verify-v1 evidence receipt)"]
    Hub --> TaskVerify

    TaskVerify --> Mech["0-Token Guard: diff-scope + mechanical-check (WaveSpecs, WorkerChanges or WorkerRoots, ProtectedPaths, DirtyDigests) + symbol-check"]
    Mech -->|"Exit 2: VIOLATION / PARTIAL_ATTRIBUTION / Findings"| FixMech["Fix ownership, scope_creep, leftovers, obsoletes, or symbol findings"]
    FixMech --> Mech
    Mech -->|"MECHANICAL_OK"| ReviewTier["Review pass (inline+XS/S+LOW: 1 reviewer; else review-loop/strategy.md)"]
    ReviewTier -->|"Blocking CONFIRMED"| LazySnap["Lazy b3-guard snapshot (pre_fix_object) -> Fix -> delta Review"]
    LazySnap --> ReviewTier
    ReviewTier -->|"Pass"| PreCommit["Commit (precommit -RequireVerifyReceipt + git commit + collapse approach)"]

    PreCommit --> MoreTasks{"More ready tasks?"}
    MoreTasks -->|"Yes"| ReadyCheck
    MoreTasks -->|"No"| MultiTask{"2+ completed tasks?"}
    MultiTask -->|"Yes"| FinalVer["Finalize: full checks + Cross-Cutting review (run_base_sha..HEAD)"]
    MultiTask -->|"No (1 task)"| FinalChecksOnly["Finalize: full checks only (skip duplicate review)"]
    FinalVer --> MergeGate{"Governed PR / Research-Ship Gate?"}
    FinalChecksOnly --> MergeGate
    MergeGate -->|"No (standard /b3-ship)"| Outcome["Set run_status: PASS | FAIL | INCOMPLETE | BLOCKED"]
    MergeGate -->|"Yes"| PolicyCheck["Provider-Neutral merge-policy-check (mode=local or optional -PrNumber b3-github-verify -> PR_READY / MERGE_AUTHORIZED / PROVIDER_UNAVAILABLE)"]
    PolicyCheck --> Outcome
```

---

## 2. Adaptive 4-Mode Wave Partitioning, Ownership Provenance & Merge Gate

Subagent logical aliases are described in [`../workflows/references/dispatch-naming.md`](../workflows/references/dispatch-naming.md) and are only requested when the host supports custom spawn names. Host-returned IDs remain authoritative for resume.

`check-wave -Partition` computes bounded `wave|N|...` sub-waves across four isolation modes (`SHARED_READ_ONLY`, `SHARED_DISJOINT_WRITES`, `ISOLATED_WRITES`, `SEQUENTIAL`). Subagents never talk directly to each other and never edit `read_only_deps`, `ProtectedPaths`, or `.b3/` state. Parent acts as the sole Hub, verifies per-worker ownership provenance (`CALLER_ATTRIBUTED` via `-WorkerChanges` or Git-proven `VERIFIED_PER_WORKER` via `-WorkerRoots`), resumes the owning `impl_agent` on delta findings, and evaluates provider-neutral `merge-policy-check` when governed merge gates apply.

```mermaid
sequenceDiagram
    participant P as Parent Orchestrator
    participant G as b3-guard CLI (0 tok)
    participant W2 as b3-impl-t002 (logical alias)
    participant W3 as b3-impl-t003 (logical alias)
    participant R as Fresh Independent Reviewer

    P->>G: check-wave -Partition (WaveSpecs, WaveReads, ProtectedPaths, CheckDirtyScope)
    G-->>P: WAVE_OK or WAVE_PARTITIONED (wave 1 PARALLEL, MaxConcurrency 1..4)
    Note over P,G: Choose SHARED_READ_ONLY, SHARED_DISJOINT_WRITES, or ISOLATED_WRITES (check-worktree -RequireIsolated -PeerRoots)

    par Launch T002
        P->>W2: Brief (owned paths + verbatim contract + scoped Verify)
    and Launch T003
        P->>W3: Brief (owned paths + verbatim contract + scoped Verify)
    end
    Note over P: Store host-returned impl_agent IDs in progress.md

    W2-->>P: <=25 lines (files_changed, cmds, discoveries, change_requests)
    W3-->>P: <=25 lines (files_changed, cmds, discoveries, change_requests)

    P->>G: diff-scope + mechanical-check (WaveSpecs, WorkerChanges or WorkerRoots, ProtectedPaths, DirtyDigests)
    G-->>P: MECHANICAL_OK (ownership_verification=CALLER_ATTRIBUTED or VERIFIED_PER_WORKER)

    P->>R: Independent review (base_sha, review_files, active findings only)
    R-->>P: <=25 lines (Verdict: BLOCKING_FINDINGS - R001 in api/orders.ts)

    P->>G: Lazy snapshot (capture pre_fix_object only because blocking findings exist)
    G-->>P: pre_fix_object SHA

    P->>W2: Resume impl_agent_2 with R001 delta only (warm prompt cache)
    W2-->>P: <=20 lines (R001 bug-class sweep + verification exit 0)

    P->>G: diff-scope --prev-sha pre_fix_object + mechanical-check
    G-->>P: delta_files=api/orders.ts and MECHANICAL_OK

    P->>R: Fresh Reviewer Pass 2 (delta_files + callers + residue)
    R-->>P: <=25 lines (Verdict: NO_BLOCKING_FINDINGS)

    P->>G: precommit -RequireVerifyReceipt (T002 AllowedPaths) then commit T002
    P->>G: precommit -RequireVerifyReceipt (T003 AllowedPaths) then commit T003

    opt Governed PR or /b3-research-ship merge gate
        P->>G: merge-policy-check (trunk .b3/research-policy.json, mode=local or optional -PrNumber b3-github-verify)
        G-->>P: PR_READY / LOCAL_ELIGIBLE_ONLY / MERGE_AUTHORIZED / PROVIDER_UNAVAILABLE
    end
```

---

## 3. `/b3-review-loop` Convergence & 2-Tier Circuit Breaker

[`../review-loop/strategy.md`](../review-loop/strategy.md) is self-sufficient at runtime (skipping `spec.md`, `sizing.md`, and `models.md` on normal runs to save ~13 KB per invocation).

```mermaid
flowchart TD
    Start["/b3-review-loop or /b3-ship Review"] --> Scope["Guard (0-Token CLI): diff-scope + mechanical-check + symbol-check"]
    Scope -->|"EMPTY_DIFF"| Incomplete["UNKNOWN / INCOMPLETE"]
    Scope -->|"Exit 2: mechanical / symbol"| FixMech["Fix scope_creep / leftovers / obsoletes / dangling symbols"]
    FixMech --> Scope
    Scope -->|"NOISE_ONLY"| NoiseTest["Verify: b3-guard verify-run / verify-check"]
    NoiseTest -->|"Green"| Pass["PASS (0 LLM review tokens)"]
    NoiseTest -->|"Red"| Fail["FAIL"]

    Scope -->|"L / XL / XXL"| Hier["Hierarchical L0-L4 (review-inventory + L1 contracts + L2 <=4 conc units + L3 cross-unit + review-ledger check)"]
    Hier --> Gate
    Scope -->|"XS / S / M"| Rev["Review: Fresh Independent Reviewer + Risk-Triggered Specialists (Iter 2+: delta_files + callers + residue; <= 25L; else SINGLE_AGENT_LIMIT)"]
    Rev --> Merge["Orchestrator merges & classifies findings (OPEN / FIXED / REJECTED / ACCEPTED / SPECULATIVE)"]
    Merge --> Gate{"Blocking OPEN == 0 AND verify-check / checks PASS?"}
    Gate -->|"Yes"| Pass2["PASS"]
    Gate -->|"No"| Breaker{"2-Tier Circuit Breaker?"}

    Breaker -->|"Same finding survives 2 rounds"| ResetSubagent["Tier 1: Brief/Subagent stuck -> rewrite brief or spawn fresh b3-fixer (drop impl_agent)"]
    Breaker -->|"Same bug_class 2 consecutive rounds"| Redesign["Tier 2: Design flaw -> stop patching, return to Scope / Design"]
    Breaker -->|"Flat/rising blockers or cap reached"| Stuck["STUCK / INCOMPLETE (or FAIL)"]
    Breaker -->|"Converging"| Snap["Capture prev_sha (b3-guard snapshot) + update state.md"]

    ResetSubagent --> Snap
    Snap --> Fix["Fix: Resume impl_agent or dispatch standalone b3-fixer (bug-class sweep in scope + verify-run; <= 20 lines)"]
    Fix --> LoopBack["Loop to diff-scope --prev-sha prev_sha"]
    LoopBack --> Scope
```

---

## 4. Standalone `/b3-review` — 3-Mode Flow (Local, GitHub PR & Safe Posting)

Standalone `/b3-review` ([`../commands/b3-review.md`](../commands/b3-review.md), [`../skills/engineering/code-review/SKILL.md`](../skills/engineering/code-review/SKILL.md)) routes into 3 explicit modes, renders every chat report and GitHub PR summary with the shared [`../skills/engineering/code-review/references/review-template.md`](../skills/engineering/code-review/references/review-template.md) (`CRITICAL` | `HIGH` | `MEDIUM` | `LOW`), and delegates authorized `--post` publication to [`../skills/engineering/pr-feedback/SKILL.md`](../skills/engineering/pr-feedback/SKILL.md) + `scripts/b3-pr-github.{ps1,sh}` (`0` extra bytes on local reviews).

```mermaid
flowchart TD
    Inv["/b3-review [target]"] --> Mode{"Target Mode?"}

    Mode -->|"Local (default)"| AutoBase["b3-guard diff-scope (auto base: dirty WT -> HEAD; clean branch -> merge-base)"]
    AutoBase --> LocalMech["b3-guard mechanical-check (+ symbol-check on refactors) + verify-check on receipts"]
    LocalMech --> LocalNoise{"size_class == NOISE_ONLY?"}
    LocalNoise -->|"Yes + green checks"| LocalPass["PASS (skip LLM review)"]
    LocalNoise -->|"No"| ReviewPass["1 Delta-First Review Pass (contracts, ACs, correctness, security, perf, residue, tests)"]

    Mode -->|"GitHub PR (#id / URL)"| LoadRef["Open references/github-pr-review.md"]
    LoadRef --> PrMeta["gh pr view --json ... --jq ... (filtered context + ticket ACs + failed checks)"]
    PrMeta --> FilterNoise["Filter out lockfiles / minified / snapshots / generated"]
    FilterNoise --> FetchDiff["Local clone: 2-step fetch base + PR head + b3-guard --target-ref FETCH_HEAD (+ symbol-check); Remote: gh api"]
    FetchDiff --> ReviewPass

    ReviewPass --> ChatReport["Compact findings report in chat (CONFIRMED vs SPECULATIVE + checked/skipped dimensions)"]
    ChatReport --> PostGate{"User requested or authorized --post to GitHub PR?"}
    PostGate -->|"No"| Done["Done (read-only review)"]
    PostGate -->|"Yes"| SignalGate["Delegate to pr-feedback + b3-pr-github comment (CONFIRMED findings only; COMMENT default)"]
    SignalGate --> PostType{"Publication mode?"}
    PostType -->|"summary / both / --draft"| SummaryCmd["b3-pr-github comment (SHA-fresh review body via stdin JSON + remote object verification)"]
    PostType -->|"inline"| InlineCmd["b3-pr-github comment (diff-hunk validated inline threads on head_sha)"]
```

---

## 5. Run-Scoped Checkpoints & Context Budget Architecture

Checkpoints are isolated per run under `.b3/ship/runs/<run_id>/` (and `.b3/research-ship/runs/<run_id>/`, gitignored) and addressed via a 1-line plain-text `CURRENT` pointer, so normal runs never scan sibling history. `diff-scope` (`Test-CheckpointPath`) excludes `.b3/{ship,research-ship,autodev}/`, so standalone `/b3-verify` receipts (`.b3/ship/verify/`) and standalone `/b3-review-loop` state (`.b3/ship/review-loop/<slug>/`) stay out of diffs without affecting `CURRENT` or `resolve-run`. Canonical PR feedback state and PID locks live under `<git-common-dir>/b3/pr-feedback/` (shared across linked worktrees), while `.b3/pr-feedback/` is gitignored local scratch only.

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
    Prune["b3-guard prune"] -.->|"Keeps newest 10 PASS; never deletes CURRENT or non-PASS"| RunDir
```

### Static Context Budgets (`scripts/measure-context.{ps1,sh} -Strict`)

All byte caps are measured in **canonical LF UTF-8 bytes** (identical across Windows PowerShell and Git Bash / macOS / Linux):

| Budget metric | Strict cap / Tracking | What it guards |
| --- | --- | --- |
| `AGENTS.md` | `<= 3,600 B` | Always-on universal repository map |
| Individual `SKILL.md` (`35` total) | `<= 4,000 B` | Keeps every canonical & command skill compact |
| Individual skill frontmatter | `<= 280 B` | Prevents always-on skill-index bloat |
| `workflows/ship.md` | `<= 9,500 B` | Core `/b3-ship` orchestrator prompt |
| `ship_refs_load` (`templates` + `resume`) | `<= 6,000 B` | On-demand `/b3-ship` progressive-disclosure refs |
| `workflows/research-ship.md` | `<= 9,500 B` | Core `/b3-research-ship` orchestrator prompt |
| `research_ship_refs` (`templates` + `resume` + `gates`) | `<= 12,000 B` | On-demand `/b3-research-ship` progressive-disclosure refs |
| `context_routing` (`workflows/references/context-routing.md`) | `<= 3,200 B` | On-demand MCP-aware routing contract (`0 B` always-on) |
| `review-loop/strategy.md` | `<= 5,400 B` | Self-sufficient runtime `/b3-review-loop` prompt |
| `review_delta_load` (`b3-reviewer.md` only) | Tracked | Self-contained per-pass independent review subagent payload |
| `review_iter_subag` (`b3-reviewer.md` + `b3-fixer.md`) | Tracked | Self-contained per-iteration reviewer + fixer subagent payloads |
| `review_hier_load` (`review_loop_op` + `hierarchical.md`) | Tracked | On-demand `L`/`XL`/`XXL` hierarchical review load |
| `standalone_cmds` (`plan`, `impl`, `debug`, `review`, `verify`) | Tracked | Single-hop static load per standalone command |
| `standalone_rev_all` (`cmd` + `code-review/SKILL.md` + `review-template.md`) | Tracked | Full standalone `/b3-review` report payload |
| `agents_roles_total` (5 runtime roles) | `<= 8,500 B` | Compact subagent role specs with strict reply caps |

---

## 6. Cost-Preserving Quality Model Tiering (4-Tier Routing)

The system separates **Deep reasoning**, **Standard execution**, **Fast surgical execution**, and **Deterministic (0-token) verification** in a host-neutral way (contract details and **Cost-Aware Escalation** in [`../review-loop/models.md`](../review-loop/models.md)):

| Tier | Roles in `/b3-ship` & Standalone Commands | Rationale & Quality Guardrail |
| --- | --- | --- |
| **Deep / high-reasoning** | `Orchestrator` (`Plan`, `Scope`), hard debugging, `b3-reviewer`, `b3-architecture-reviewer`, `b3-security-reviewer`, `b3-performance-reviewer` | Preserves design quality, invariants, API contracts, and independent defect detection |
| **Standard execution** | Complex multi-file implementation, shared contract integration, large refactors | Keeps state and invariants stable before verification and reduces costly retry loops |
| **Fast execution** | Small-scope coding (`inline`/`notes`), surgical `b3-fixer` edits (pinned `file:line` + `bug_class`), routine tests, docs | Reduces cost and latency once scope and contracts are clear; escalates 1 tier on circuit breaker or repeated `verify-run` failures |
| **Deterministic (0-token)** | `b3-guard` (`diff-scope`, `mechanical-check`, `symbol-check`, `verify-run`/`check`, `check-wave -Partition`, `check-worktree`, `merge-policy-check`, `context-cache`, `precommit`), Git, lint, builds | Deterministic structural verification via CLI with zero token cost and zero hallucination |

---

## Related canonical documents

- Core `/b3-ship` & `/b3-research-ship` procedures & PR template: [`../workflows/ship.md`](../workflows/ship.md), [`../workflows/research-ship.md`](../workflows/research-ship.md), [`../workflows/references/pr-template.md`](../workflows/references/pr-template.md)
- Core `/b3-review-loop` procedure: [`../review-loop/strategy.md`](../review-loop/strategy.md)
- Core `/b3-review` & PR feedback skills: [`../skills/engineering/code-review/SKILL.md`](../skills/engineering/code-review/SKILL.md), [`../skills/engineering/pr-feedback/SKILL.md`](../skills/engineering/pr-feedback/SKILL.md), [`../skills/engineering/code-review/references/review-template.md`](../skills/engineering/code-review/references/review-template.md), [`../skills/engineering/code-review/references/github-pr-review.md`](../skills/engineering/code-review/references/github-pr-review.md)
- Deterministic CLI reference: [`../scripts/README.md`](../scripts/README.md)
- Architecture decisions: [`../research/decisions/decision-012-autodev-v2-hardening.md`](../research/decisions/decision-012-autodev-v2-hardening.md), [`../research/decisions/decision-013-host-neutral-multi-host-layout.md`](../research/decisions/decision-013-host-neutral-multi-host-layout.md), [`../research/decisions/decision-014-autodev-parallel-waves-and-mechanical-pass.md`](../research/decisions/decision-014-autodev-parallel-waves-and-mechanical-pass.md), [`../research/decisions/decision-015-evidence-gates-tripwires-and-context-budgets.md`](../research/decisions/decision-015-evidence-gates-tripwires-and-context-budgets.md), [`../research/decisions/decision-016-standalone-commands-quality-and-context.md`](../research/decisions/decision-016-standalone-commands-quality-and-context.md), [`../research/decisions/decision-018-research-ship-workflow.md`](../research/decisions/decision-018-research-ship-workflow.md)
