# Ship & Review Visual Guide

Architecture, execution flow, and context-optimization reference for `/b3-ship`, `/b3-review-loop`, and standalone `/b3-review`.

> [!NOTE]
> This guide is human-facing documentation (`0` runtime LLM tokens). Canonical agent procedures stay in [`../workflows/ship.md`](../workflows/ship.md), [`../review-loop/strategy.md`](../review-loop/strategy.md), and [`../skills/engineering/code-review/SKILL.md`](../skills/engineering/code-review/SKILL.md).

---

## 1. `/b3-ship` End-to-End Lifecycle

Core 7-step flow: `Preflight → Plan → [Scope → Build → Verify → Review → Commit] → Finalize`.

```mermaid
flowchart TD
    Entry["Host Entrypoint (1-hop): Cursor / Codex / Claude / Antigravity"] --> Resolve{"Mode?"}
    Resolve -->|"status / --all"| StatusOut["b3-guard resolve-run or list-runs (report only)"]
    Resolve -->|"resume / unfinished run"| Resume["Scenario C: ship-resume.md (reconcile checkpoints vs Git)"]
    Resolve -->|"New requirement / plan"| NewRun["b3-guard new-run (.b3/ship/runs/run_id + CURRENT)"]

    NewRun --> PreFlight["Preflight: initial_dirty_paths + checks (baseline non-blocking or on-demand)"]
    PreFlight --> Plan["Plan (master-plan.md): Invariants, AC1..ACn, Verbatim Shared Contracts"]
    Plan --> ReadyCheck["Select Ready Tasks (pending + all depends_on completed)"]
    Resume --> ReadyCheck

    ReadyCheck --> Scope["Scope (JIT per task): files vs read_only_deps + Readiness Gate"]
    Scope --> PreReview{"depth == detailed?"}
    PreReview -->|"Yes"| DesignRev["1-Pass Pre-code Review (design-only): architecture (contrarian) + security"]
    DesignRev -->|"CONFIRMED flaw"| Scope
    DesignRev -->|"Clean"| WaveCheck
    PreReview -->|"No (inline / notes)"| WaveCheck

    WaveCheck{"2+ ready tasks?"}
    WaveCheck -->|"Yes"| GuardWave["b3-guard check-wave (verify disjoint OWNED FILES)"]
    GuardWave -->|"WAVE_OK"| Parallel["Build Parallel Wave (2-3 workers; save impl_agent in progress.md)"]
    GuardWave -->|"WAVE_CONFLICT"| SeqImpl["Build Single Task"]
    WaveCheck -->|"No"| SeqImpl

    Parallel --> Hub["Parent Hub Relay: merge discoveries & change_requests + scoped Verify"]
    SeqImpl --> TaskVerify["Verify: run scoped tests (probe baseline on-demand only if red)"]
    Hub --> TaskVerify

    TaskVerify --> Mech["Review step - 0-Token Guard: diff-scope + mechanical-check"]
    Mech -->|"Exit 2: Findings"| FixMech["Fix mechanical findings first"]
    FixMech --> Mech
    Mech -->|"MECHANICAL_OK"| ReviewTier["Review pass (inline+SMALL: 1 reviewer; else review-loop/strategy.md)"]
    ReviewTier -->|"Blocking CONFIRMED"| LazySnap["Lazy b3-guard snapshot (pre_fix_object) -> Fix -> delta Review"]
    LazySnap --> ReviewTier
    ReviewTier -->|"Pass"| PreCommit["Commit (sequential b3-guard precommit + git commit + collapse approach to 1 line)"]

    PreCommit --> MoreTasks{"More ready tasks?"}
    MoreTasks -->|"Yes"| ReadyCheck
    MoreTasks -->|"No"| MultiTask{"2+ completed tasks?"}
    MultiTask -->|"Yes"| FinalVer["Finalize: full checks + Cross-Cutting review (run_base_sha..HEAD)"]
    MultiTask -->|"No (1 task)"| FinalChecksOnly["Finalize: full checks only (skip duplicate review)"]
    FinalVer --> Outcome["Set run_status: PASS | FAIL | INCOMPLETE | BLOCKED"]
    FinalChecksOnly --> Outcome
```

---

## 2. Parallel Disjoint Wave, Hub-and-Spoke & Prompt-Cache Resume

Workers never talk directly to each other and never edit `read_only_deps` or shared contracts. Parent acts as the sole Hub, records `impl_agent` IDs in `progress.md`, keeps Reviewers strictly independent, captures `snapshot` lazily only when fixes are needed, and **resumes the owning `impl_agent`** with delta findings to preserve worker prompt cache.

```mermaid
sequenceDiagram
    participant P as Parent Orchestrator
    participant G as b3-guard CLI (0 tok)
    participant W2 as Worker T002 (impl_agent_2)
    participant W3 as Worker T003 (impl_agent_3)
    participant R as Fresh Independent Reviewer

    P->>G: check-wave (T002=api/orders.ts, T003=ui/OrderPanel.tsx)
    G-->>P: WAVE_OK: disjoint (2 tasks, 2 paths)

    par Launch T002
        P->>W2: Brief (paths + verbatim contract + scoped Verify)
    and Launch T003
        P->>W3: Brief (paths + verbatim contract + scoped Verify)
    end
    Note over P: Record impl_agent_2 and impl_agent_3 in progress.md

    W2-->>P: <=25 lines (files_changed, cmds, discoveries, change_requests)
    W3-->>P: <=25 lines (files_changed, cmds, discoveries, change_requests)

    P->>G: diff-scope + mechanical-check
    G-->>P: MECHANICAL_OK (scope_creep=none, leftovers=none, obsolete_hits=none)

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

    P->>G: precommit (T002 AllowedPaths) then commit T002
    P->>G: precommit (T003 AllowedPaths) then commit T003
```

---

## 3. `/b3-review-loop` Convergence & 2-Tier Circuit Breaker

[`../review-loop/strategy.md`](../review-loop/strategy.md) is self-sufficient at runtime (skipping `spec.md`, `sizing.md`, and `models.md` on normal runs to save ~13 KB per invocation).

```mermaid
flowchart TD
    Start["/b3-review-loop or /b3-ship Review"] --> Scope["Guard (0-Token CLI): diff-scope + mechanical-check"]
    Scope -->|"EMPTY_DIFF"| Incomplete["UNKNOWN / INCOMPLETE"]
    Scope -->|"Exit 2: mechanical"| FixMech["Fix scope_creep / leftovers / obsoletes"]
    FixMech --> Scope
    Scope -->|"NOISE_ONLY"| NoiseTest["Verify: run build/tests only"]
    NoiseTest -->|"Green"| Pass["PASS (0 LLM review tokens)"]
    NoiseTest -->|"Red"| Fail["FAIL"]

    Scope -->|"SMALL / MEDIUM / LARGE"| Rev["Review: Fresh Independent Reviewer (Iter 2+: delta_files + callers + residue; <= 25 lines)"]
    Rev --> Merge["Orchestrator merges & classifies findings (OPEN / FIXED / REJECTED / ACCEPTED / SPECULATIVE)"]
    Merge --> Gate{"Blocking OPEN == 0 AND checks PASS?"}
    Gate -->|"Yes"| Pass2["PASS"]
    Gate -->|"No"| Breaker{"2-Tier Circuit Breaker?"}

    Breaker -->|"Same finding survives 2 rounds"| ResetWorker["Tier 1: Brief/Worker stuck -> rewrite brief or spawn fresh Fixer (drop impl_agent)"]
    Breaker -->|"Same bug_class 2 consecutive rounds"| Redesign["Tier 2: Design flaw -> stop patching, return to Scope / Design"]
    Breaker -->|"Flat/rising blockers or cap reached"| Stuck["STUCK / INCOMPLETE (or FAIL)"]
    Breaker -->|"Converging"| Snap["Capture prev_sha (b3-guard snapshot)"]

    ResetWorker --> Snap
    Snap --> Fix["Fix: Resume owning impl_agent (or fresh Fixer): bug-class sweep in OWNED FILES + delete replaced symbols (<= 20 lines)"]
    Fix --> LoopBack["Loop to diff-scope --prev-sha prev_sha"]
    LoopBack --> Scope
```

---

## 4. Standalone `/b3-review` — 3-Mode Flow (Local, GitHub PR & Safe Posting)

Standalone `/b3-review` ([`../commands/b3-review.md`](../commands/b3-review.md), [`../skills/engineering/code-review/SKILL.md`](../skills/engineering/code-review/SKILL.md)) routes into 3 explicit modes and only loads [`../skills/engineering/code-review/references/github-pr-review.md`](../skills/engineering/code-review/references/github-pr-review.md) when a GitHub PR or PR comment is involved (`0` extra bytes on local reviews).

```mermaid
flowchart TD
    Inv["/b3-review [target]"] --> Mode{"Target Mode?"}

    Mode -->|"Local (default)"| AutoBase["b3-guard diff-scope (auto base: dirty WT -> HEAD; clean branch -> merge-base)"]
    AutoBase --> LocalMech["b3-guard mechanical-check (0 tokens)"]
    LocalMech --> LocalNoise{"size_class == NOISE_ONLY?"}
    LocalNoise -->|"Yes + green checks"| LocalPass["PASS (skip LLM review)"]
    LocalNoise -->|"No"| ReviewPass["1 Evidence-Based Code Review Pass (correctness, security, perf, residue, tests)"]

    Mode -->|"GitHub PR (#id / URL)"| LoadRef["Open references/github-pr-review.md"]
    LoadRef --> PrMeta["gh pr view --json ... --jq ... (filtered context + failed checks)"]
    PrMeta --> FilterNoise["Filter out lockfiles / minified / snapshots / generated"]
    FilterNoise --> FetchDiff["Local clone: 2-step fetch base + PR head + b3-guard --target-ref FETCH_HEAD; Remote: paginated gh api"]
    FetchDiff --> ReviewPass

    ReviewPass --> ChatReport["Compact findings report in chat (CONFIRMED vs SPECULATIVE + checked/skipped dimensions)"]
    ChatReport --> PostGate{"User requested or confirmed posting to GitHub PR?"}
    PostGate -->|"No"| Done["Done (read-only review)"]
    PostGate -->|"Yes"| SignalGate["Safety Gates: CONFIRMED findings with file:line only; COMMENT default (never unasked APPROVE/REQUEST_CHANGES)"]
    SignalGate --> PostType{"Comment style?"}
    PostType -->|"Summary"| SummaryCmd["Write temp .md -> gh pr review --comment --body-file (delete temp file)"]
    PostType -->|"Inline (Files changed)"| InlineCmd["Write temp .json (commit_id, path, line, side: RIGHT) -> gh api pulls/id/reviews --input (delete temp file)"]
```

---

## 5. Run-Scoped Checkpoints & Context Budget Architecture

Checkpoints are isolated per run under `.b3/ship/runs/<run_id>/` (gitignored) and addressed via a 1-line plain-text `.b3/ship/CURRENT` pointer, so normal runs never scan sibling history.

```mermaid
flowchart LR
    Cur[".b3/ship/CURRENT (1 line: run_id, ~45 B)"] --> RunDir[".b3/ship/runs/run_id/"]
    RunDir --> MP["master-plan.md (Invariants, Shared contracts, Tasks)"]
    RunDir --> PR["progress.md (run_status, SHAs, impl_agent, collapsed approaches)"]
    RunDir --> FN["findings.md (Sole monotonic R001.. log)"]
    RunDir --> AP["approach/T00N.md (optional: notes / detailed)"]
    RunDir --> LG["logs/ (optional: long failing test logs)"]

    Prune["b3-guard prune"] -.->|"Keeps newest 10 PASS; never deletes CURRENT or non-PASS"| RunDir
```

### Static Context Budgets (`scripts/measure-context.{ps1,sh} -Strict`)

All byte caps are measured in **canonical LF UTF-8 bytes** (identical across Windows PowerShell and Git Bash / macOS / Linux):

| Budget metric | Strict cap | What it guards |
| --- | --- | --- |
| `AGENTS.md` | `<= 3,600 B` | Always-on universal repository map |
| Individual `SKILL.md` | `<= 4,000 B` | Keeps every skill compact and focused |
| Individual skill frontmatter | `<= 280 B` | Prevents always-on skill-index bloat |
| `workflows/ship.md` | `<= 9,500 B` | Core `/b3-ship` orchestrator prompt |
| `ship_refs_load` (`templates` + `resume`) | `<= 6,000 B` | On-demand `/b3-ship` progressive-disclosure refs |
| `review-loop/strategy.md` | `<= 5,400 B` | Self-sufficient runtime `/b3-review-loop` prompt |
| `agents_roles_total` (5 runtime roles) | `<= 8,500 B` | Compact subagent role specs with strict reply caps |

---

## 6. Phân tầng Model tối ưu chi phí (Cost-Preserving Model Tiering)

Hệ thống tách biệt tầng **suy luận sâu (Deep / high-reasoning)** và tầng **thực thi phẫu thuật (Fast / surgical coding)** theo hướng host-neutral (chi tiết contract tại [`../review-loop/models.md`](../review-loop/models.md)):

| Tầng | Vai trò trong `/b3-ship` & `/b3-review-loop` | Lý do & Bảo vệ chất lượng |
| --- | --- | --- |
| **Deep / high-reasoning** | `Orchestrator` (`Plan`, `Scope`), `b3-reviewer`, `b3-architecture-reviewer`, `b3-security-reviewer`, `b3-performance-reviewer` | Giữ nguyên chất lượng thiết kế, invariant, hợp đồng API và phát hiện bug độc lập |
| **Fast / surgical coding** | `Build` worker (`impl_agent` sau `Gate`), `b3-fixer` (nhận `file:line` + `bug_class`) | Giảm chi phí/latency khi sửa code có phạm vi rõ ràng; được bảo vệ bởi `0`-token CLI `mechanical-check`, test thực thi (`Verify`) và **Deep** `b3-reviewer` độc lập |

---

## Related canonical documents

- Core `/b3-ship` procedure: [`../workflows/ship.md`](../workflows/ship.md)
- Core `/b3-review-loop` procedure: [`../review-loop/strategy.md`](../review-loop/strategy.md)
- Core `/b3-review` skill & GitHub PR ref: [`../skills/engineering/code-review/SKILL.md`](../skills/engineering/code-review/SKILL.md), [`../skills/engineering/code-review/references/github-pr-review.md`](../skills/engineering/code-review/references/github-pr-review.md)
- Deterministic CLI reference: [`../scripts/README.md`](../scripts/README.md)
- Architecture decisions: [`../research/decisions/decision-012-autodev-v2-hardening.md`](../research/decisions/decision-012-autodev-v2-hardening.md), [`../research/decisions/decision-013-host-neutral-multi-host-layout.md`](../research/decisions/decision-013-host-neutral-multi-host-layout.md), [`../research/decisions/decision-014-autodev-parallel-waves-and-mechanical-pass.md`](../research/decisions/decision-014-autodev-parallel-waves-and-mechanical-pass.md)
