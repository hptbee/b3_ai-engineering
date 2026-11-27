# Evaluation

This repository will evaluate **itself**: whether the right artifact activates, whether the result is good, whether failure is honest, and whether the review loop actually improves the work.

Application test suites for product work live in those products. Evals here live under `evals/` when they exist.

**Status:** YAML schema, activation, boundary, rule, command, review-loop, and workflow fixtures live under `evals/` and run via `cargo test --test eval_contracts`. Automated LLM runner, CI, and capability benchmarks **deferred** (decision-005). See [`evals/README.md`](../evals/README.md) for current fixture counts/layout and [`ci-architecture.md`](ci-architecture.md) for the test ownership matrix.

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

## Fixture coverage & native contract suites

Live folder inventory and fixture counts across `skills/`, `rules/`, `agents/`, `commands/`, `workflows/`, and `review-loop/` are maintained in [`../evals/README.md`](../evals/README.md) (and [`../evals/review-loop/README.md`](../evals/review-loop/README.md)); the native Rust integration test ownership matrix (`cargo test --test eval_contracts` and sibling suites) lives in [`ci-architecture.md`](ci-architecture.md). A loop that always reports success is a failed loop; a loop that always reports dozens of speculative issues is also a failed loop. Native tests verify CLI, Git, and filesystem contracts — not live Cursor slash-command or IDE runtime discovery.

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

**Priority:** Establish a paired **same-host, same-model** benchmark before claiming B3 reduces token usage or costs. This is the acceptance method for the [roadmap](roadmap.md); it is not implemented telemetry or an observed result.

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

### Paired harness-efficiency baseline (not yet run)

1. **Corpus:** Use representative real-world tasks grouped XS/S/M/L/XL/XXL, each with a frozen starting Git state, acceptance criteria, allowed scope, and independent verification. Separate bugfix, feature, refactor, and review-heavy cases where practical.
2. **Arms:** Compare the current coding-agent host without B3 against the *same host, same model, same effort/settings, same task* with B3. Repeat enough runs to expose variance and record failures. Different model/provider comparisons are separate experiments; do not attribute their price or quality differences to the harness.
3. **Metering:** Record actual input/output/cached tokens and billable cost if reported by the host; include parent, child, reviewer, fixer, retry, and integration steps. Also capture wall-clock time, verified completion, defects/regressions, review passes, number of subagents, and manual intervention count.
4. **Missing data:** Mark model usage or cost `UNKNOWN` when not exposed. Keep static bytes and estimated tokens in separate columns; do not convert them to asserted billed cost.
5. **Decision:** Compare distribution by task size and total *cost per verified completed task* (total run cost including failed attempts divided by verified completions). Reject any apparent saving that weakens safety, review independence, or evidence quality. Keep beneficial optimizations and remove repeated coordination overhead that does not pay for itself.
6. **Portability later:** When a new coding-agent CLI is available in an authorized environment, validate the identical acceptance/evidence contracts through its adapter. Never require proprietary logs, API specs, or credentials in public fixtures.

**Artifact:** A reproducible results table with task IDs, host/model/settings, evidence refs, telemetry availability, observed metrics, and clear `PASS`/`FAIL`/`UNKNOWN` labels. Do not state a percentage improvement before this benchmark exists.

### Structural comparison: Sequential vs. Parallel scenarios

| Scenario | Recommended mode | Structural rationale |
| --- | --- | --- |
| Tiny, overhead-dominated tasks (e.g., 1–2 small edits or single-file fix) | Sequential | Orchestration, wave checks, and Context Packet overhead exceed any concurrency gain |
| 2+ disjoint medium/large modules with worktree/path isolation | Bounded parallel wave | Independent writes/reads amortize coordination overhead and reduce wall-clock latency |
| Partially conflicting tasks (shared contracts, ledgers, or overlapping `watched_paths`) | Partitioned sub-waves + single-writer integration | Independent slices run concurrently; shared-state updates serialize to avoid rework and `WAVE_CONFLICT` |
