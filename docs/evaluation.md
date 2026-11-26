# Evaluation

This repository will evaluate **itself**: whether the right artifact activates, whether the result is good, whether failure is honest, and whether the review loop actually improves the work.

Application test suites for product work live in those products. Evals here live under `evals/` when they exist.

**Status:** `304` YAML schema/activation and lifecycle fixtures across `skills/` (`181`), `workflows/` (`64`), `review-loop/` (`26`), `commands/` (`16`), `rules/` (`10`), and `agents/` (`7`). Automated LLM runner, CI, and capability benchmarks **deferred** (decision-005). See [`evals/README.md`](../evals/README.md).

## Intended layout

```text
evals/
├── skills/
│   └── <skill>/
│       ├── should-trigger/
│       ├── should-not-trigger/
│       └── near-miss/
│
├── rules/
│
├── agents/
│
├── commands/
│
├── workflows/
│   ├── ship/
│   └── research-ship/
│
└── review-loop/
    ├── false-positive/
    ├── false-convergence/
    ├── tool-failure/
    ├── iteration-limit/
    ├── finding-lifecycle/
    ├── adaptive-sizing/
    ├── quality-gate/
    └── orchestration/
```

Empty case directories are omitted until a real case exists. See [`../evals/README.md`](../evals/README.md).

## What to test

Evaluation covers four questions. A green “it wrote something” is not enough.

### Capability

Does the system produce a **good result** when the right skill/rule/agent is used? Correctness, clarity, portability, token efficiency, progressive disclosure, verification, failure handling.

### Activation

Did the **correct** skill, rule, or agent activate?

For skills, cases in three buckets:

```text
should-trigger
should-not-trigger
near-miss
```

| Bucket | Meaning |
| --- | --- |
| Should trigger | A realistic request where this skill is the right method |
| Should not trigger | A request outside the skill, including unrelated work |
| Near miss | Related wording that should activate a *different* skill or no skill |

A skill fails activation evals if it is silent on should-trigger cases, greedy on should-not-trigger cases, or consistently wins near-misses that belong elsewhere.

Trigger evals read the skill `description` and `SKILL.md` “when not to use” text. If those texts cannot separate the buckets, the skill is not ready.

Rules and agents get analogous comply / violate / wrong-role cases when those layers exist.

### Safety

Does the system **fail safely**? Tool failure, missing diff, incomplete evidence → `UNKNOWN / INCOMPLETE` (or FAIL with remaining confirmed issues) — never a fake PASS. Preferences must not override security or hard rules ([`precedence.md`](precedence.md)).

### Convergence

Does the review loop **actually improve** the implementation? Fixes map to findings; verification runs; lifecycle moves `CONFIRMED` → `FIXED` → `VERIFIED`; the loop does not declare PASS on stagnation, identical reviews, or iteration exhaustion.

## Skill quality (capability detail)

When a skill is applied to a fixture (or a recorded real task), score at least:

| Dimension | Ask |
| --- | --- |
| Correctness | Does following it produce a sound engineering result? |
| Clarity | Can an agent execute it without improvising the method? |
| Portability | Does it avoid host-specific coupling? |
| Token efficiency | Is the main file small, with details deferred? |
| Progressive disclosure | Are references opened only when needed? |
| Verification | Does it demand evidence and forbid fake PASS? |
| Failure handling | Does it degrade to UNKNOWN / INCOMPLETE instead of guessing? |

Quality evals need fixtures with a known good outcome, not only prompt sniff tests.

## Review-loop eval folders (`26` YAML cases across `8` folders)

| Folder | Cases | Protects |
| --- | ---: | --- |
| `false-positive/` | 2 | Speculative noise not treated as confirmed defects |
| `false-convergence/` | 2 | No-op diffs, repeated findings, papered-over disagreement |
| `tool-failure/` | 2 | Failed/missing tools → INCOMPLETE, not PASS |
| `iteration-limit/` | 1 | Budget exhaustion → INCOMPLETE, not PASS |
| `finding-lifecycle/` | 2 | Status transitions and severity ≠ confidence |
| `adaptive-sizing/` | 8 | 6-tier T-shirt sizing (`XS`..`XXL`), delta re-review, hierarchical `L0`–`L4` unit bounds, and decoupled risk dispatch |
| `quality-gate/` | 1 | Non-blocking `LOW` remaining + zero open blockers + verified tests → `PASS` |
| `orchestration/` | 8 | Single trigger vs single-pass `/b3-review`, independent reviewer/fixer, specialist routing, residue sweep, and `SINGLE_AGENT_LIMIT` honesty |

A loop that always reports success is a failed loop. A loop that always reports dozens of speculative issues is also a failed loop.

## Workflow & command eval folders

`evals/workflows/ship/` (`50` YAML cases) holds lifecycle fixtures for `workflows/ship.md`, `evals/workflows/research-ship/` (`14` YAML cases) holds research-first delivery fixtures for `workflows/research-ship.md`, and `evals/commands/` (`16` YAML cases) holds boundary, evidence, PR-feedback, and convergence fixtures across standalone and `/b3-pr-*` commands (`/b3-plan`, `/b3-implement`, `/b3-debug`, `/b3-review`, `/b3-review-loop`, `/b3-verify`, `/b3-pr-resolve`, `/b3-pr-reply`, `/b3-pr-comment`). Each case names the artifact, the situation, and the required outcome (`PASS`, `FAIL`, `INCOMPLETE`, or `BLOCKED`). All `304` YAML cases are schema-checked via `scripts/validate-evals.sh`. Deterministic guard, receipt provenance, PR feedback, merge security, isolation, install, hierarchical review, context routing, model preferences, and resume ancestry behavior have dual-shell/PowerShell sandbox suites (`scripts/validate-ship-behavior.ps1`, `scripts/validate-standalone-commands.ps1`, `scripts/validate-pr-feedback.ps1`, `scripts/validate-merge-security.sh`, `scripts/validate-tshirt-hierarchical.ps1`, `scripts/validate-research-ship.ps1`, `scripts/validate-context-routing.ps1`, `scripts/validate-model-preferences.ps1`, `scripts/validate-cursor-global.ps1`, `scripts/validate-antigravity-global.ps1`) and an isolated product-repo smoke (`scripts/smoke-ship-product.ps1`). Those scripts are not a live Cursor slash-command or Codex runtime test.

## Honesty metrics

- False PASS rate (claimed success without evidence)
- False FAIL rate (noise presented as confirmed issues)
- Stagnation escapes (loop stops with PASS while findings are unchanged)
- Skip-without-reason rate (review dimensions silently omitted)

## Adding evals later

Each case should record: intent, input, expected bucket or outcome, and the artifact under test. Add a case when the behavior is worth protecting — after the research phase and first domain skills, not before.

## What evaluation is not

- Not a substitute for verifying a product change
- Not a leaderboard for prompt cleverness
- Not an excuse to freeze the system; evals should make change safer

## Optimization measurement (proposed methodology)

> **Status: proposed, not verified.** The runtime metrics and formulas below are evaluation methodology specifications aligned with [`engineering-philosophy.md`](engineering-philosophy.md). Zero runtime telemetry infrastructure is implemented or wired by this document.

Optimization claims (context reduction, model routing, or parallel dispatch) should be evaluated end-to-end across nine proposed dimensions:

| # | Dimension | Proposed definition / signal (not verified) |
| --- | --- | --- |
| 1 | Verified useful results | Count of tasks/ACs reaching verified completion (`PASS` with receipts) without regressions |
| 2 | Total execution cost | Sum of worker, retry, orchestration, verification, review, and integration costs |
| 3 | Token / context consumption | Input + output + cached tokens across parent orchestrator, workers, reviewers, and fixers |
| 4 | Orchestration overhead | Parent planning, wave-check, Context Packet construction, and result aggregation cost |
| 5 | Retry and review cost | Extra iterations, `b3-fixer` hops, and re-verification triggered by defects or wave conflicts |
| 6 | Execution latency | Wall-clock time from run start to verified commit (including sequential integration) |
| 7 | Parallel utilization | Fraction of eligible independent tasks executed concurrently without idle stalls |
| 8 | Failed or blocked waves | Waves aborted or serialized due to `WAVE_CONFLICT`, dirty worktrees, or shared-state contention |
| 9 | False `PASS` rate | Unverified or unsound completions escaping gates (must remain `0`; safety non-negotiable) |

### Proposed composite efficiency lens (not verified)

```text
Efficiency (proposed) = Verified useful results
                      / Total execution cost (retries + orchestration + verification + review + integration)
```

Subject to hard constraints: false `PASS` rate `= 0` and all precedence/verification invariants satisfied.

### Structural comparison: Sequential vs. Parallel scenarios

| Scenario | Recommended mode | Structural rationale |
| --- | --- | --- |
| Tiny, overhead-dominated tasks (e.g., 1–2 small edits or single-file fix) | Sequential | Orchestration, wave checks, and Context Packet overhead exceed any concurrency gain |
| 2+ disjoint medium/large modules with worktree/path isolation | Bounded parallel wave | Independent writes/reads amortize coordination overhead and reduce wall-clock latency |
| Partially conflicting tasks (shared contracts, ledgers, or overlapping `watched_paths`) | Partitioned sub-waves + single-writer integration | Independent slices run concurrently; shared-state updates serialize to avoid rework and `WAVE_CONFLICT` |
