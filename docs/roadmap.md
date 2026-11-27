# B3 Roadmap — Outcome-First, Host-Neutral Engineering Harness

**Status:** Direction and acceptance criteria, not a claim that all phases are implemented. This is the single canonical roadmap for B3; architecture and current maturity are documented separately in [architecture.md](architecture.md) and [system-lifecycle.md](system-lifecycle.md).

## North star

**Deliver verified engineering work with the least practical total token/context cost, latency, retries, and human intervention — without weakening correctness, security, or review independence.**

B3 began as a lightweight way to make everyday coding agents more efficient under constrained model usage. Success means better **cost per verified completed task** and developer throughput, not more guards, skills, subagents, or framework layers.

- **Today:** Optimize the existing Cursor-centered daily workflow, while preserving the canonical skills, commands, review-loop, and Rust deterministic core across supported hosts.
- **Future:** Allow a different coding-agent CLI/runtime to consume B3 through a small, public, capability-oriented boundary. A private or custom adapter may live outside this public repository. No organization-specific implementation detail is required here.
- **Not the default goal:** Build a new model gateway, IDE, standalone coding agent, or agent runtime merely to replace an existing host.

## Current baseline (present vs. not verified)

| Area | Current position |
| --- | --- |
| Native deterministic execution | Present: Rust `b3` handles guards, verification, context measurement, PR checks, and installation. |
| Host-neutral guidance | Present: canonical rules/skills/commands with adapters for Cursor, Codex, Claude Code, and Antigravity. |
| Orchestration | Present as host-executed `/b3-ship`, `/b3-research-ship`, and review-loop procedures; this is **not** a standalone agent scheduler. |
| Context/cost discipline | Present as static budgets, optional model preferences, delta/context routing, risk-based dispatch; **runtime token/cost savings remain unmeasured**. |
| Agent runtime API | **Not implemented** by B3: model sessions, model API calls, tool-use loop, and standalone scheduler remain responsibilities of the active host. |
| Real-host acceptance | Host UI behavior, end-to-end outcomes, and non-Cursor runtime integration require explicit validation; do not infer them from filesystem or CLI tests. |

## Delivery phases

### P0 — Stable baseline and honest measurement (first)

**Build:** Keep native Rust core and existing host workflows reliable. Verify clean CI across supported OSs and resolve regressions before adding architectural scope. Define a representative XS/S/M/L/XL/XXL task corpus and capture a *same-host, same-model, same-task* baseline with and without B3.

**Exit evidence:** Reproducible tasks and recorded inputs, model/settings, completed acceptance criteria, actual usage when the host exposes it, wall-clock time, retries, review passes, and human interventions. Separate observed metrics from approximations and missing telemetry.

### P1 — Cost-aware orchestration on real tasks (primary product value)

**Build:** Improve dispatch/no-dispatch decisions, minimum-context handoffs, delta-first review, verified cache reuse, and stopping conditions. Keep cheap tasks inline, isolate only when risk requires, and use deterministic `b3` checks instead of model calls where equivalent.

**Exit evidence:** Paired end-to-end task comparison shows lower *total cost per verified result* or better verified outcomes at justified cost, without increasing false PASS, security failures, or human recovery. Remove or simplify optimizations that repeatedly cost more than they save. Report by task size; no invented percentage target.

### P2 — Minimal external runtime boundary (conditional)

**Trigger:** A real non-Cursor coding-agent runtime must execute a B3 workflow. Do not implement ahead of an actual integration need.

**Build:** Specify the smallest adapter capabilities the workflow needs (e.g., launch task, observe events/status, cancel, optional resume, optional usage reports); expose unsupported capabilities explicitly. Validate against an entirely public mock/fake adapter. Keep `src/guard/` and canonical guidance independent of runtime-specific APIs, credentials, and model identifiers.

**Exit evidence:** One existing workflow completes unchanged via a mock adapter, with correct failure/permission handling; documentation explains which capabilities are required, optional, or unavailable. Do not claim private runtime compatibility based solely on mocks.

### P3 — Portable harness validation and selective adoption (conditional)

**Trigger:** A permitted runtime is available for testing in its own environment.

**Build:** Run the same task corpus and verification/evidence contracts on both the current host and the new runtime. Keep integration code and sensitive operational details in the authorized environment; public B3 records only generic, non-sensitive lessons when permitted. Improve adapters only for gaps observed in real tasks.

**Exit evidence:** Real-host acceptance demonstrates correct dispatch, tool permissions, cancel/resume where supported, usage visibility, and verified outcomes with measured cost. An alternative host becomes supported only after evidence, not by declaration.

### Later, only if justified — Standalone agent runtime

Build a standalone model/tool/session runtime **only** when existing hosts and adapters cannot meet a demonstrated need and measured benefits exceed operational/security maintenance cost. This is an optional decision, **not** a committed phase of the current roadmap.

## Evaluation and decision rules

- Compare **host without B3** vs. **same host with B3** first; then compare alternative runtime integrations separately. Do not attribute differences between distinct models to the harness.
- Capture all orchestrator, builder, reviewer, fixer, retry, verification, and integration overhead. Core indicators: verified completion, total tokens/usage, cost per verified completed task, wall-clock latency, defect/regression rate, and human intervention count.
- If usage is unavailable, report `UNKNOWN` and measure observable proxies separately; static character-to-token estimates are not billed token measurements.
- Treat quality and security as constraints. A faster or cheaper unverified result is not a win.
- Prefer removing duplicated guard paths or redundant prompts to adding new frameworks. A single observed incident does not justify a permanent universal rule.
- Do not publish proprietary CLI specs, credentials, endpoints, source code, usage logs, or company-specific adapters in this repository.

**Measurement details:** [evaluation.md](evaluation.md). **Governing principles:** [engineering-philosophy.md](engineering-philosophy.md). **Current maturity:** [system-lifecycle.md](system-lifecycle.md).
