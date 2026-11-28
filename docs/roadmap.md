# B3 Roadmap — Multi-Host, Host-Neutral, Cost-Aware Engineering Harness

**Status:** Direction and acceptance criteria, not a claim that all phases are implemented. This is the single canonical roadmap for B3; architecture and current maturity are documented separately in [architecture.md](architecture.md) and [system-lifecycle.md](system-lifecycle.md).

## North star

**Deliver verified engineering work with the least practical total token/context cost, latency, retries, and human intervention — without weakening correctness, security, or review independence.**

B3 began as a lightweight way to make everyday coding agents more efficient under constrained model usage. Success means better **verified work per total execution cost** and developer throughput, not more guards, skills, subagents, or framework layers.

- **Today:** Multi-host daily workflow across **Cursor**, **Codex**, and **Antigravity** (plus the supported **Claude Code** adapter), preserving canonical skills, commands, review-loop, and the deterministic Rust `b3` core without host lock-in.
- **Future:** Allow additional coding-agent CLIs or runtimes to consume B3 through a small, public, capability-oriented boundary. Private or custom adapters remain outside this public repository.
- **Not the default goal:** Build a new model gateway, IDE, standalone coding agent, or standalone agent runtime merely to replace an existing host. Hosts own LLM execution.

## Current baseline (implemented vs. planned / unverified)

| Area | Current position |
| --- | --- |
| Native deterministic execution | **Implemented:** Rust `b3` handles guards, verification, typed config/routing (`b3 config`), context measurement, PR checks, adapter sync, and installation (`0` LLM tokens for deterministic checks). |
| Host-neutral guidance & adapters | **Implemented:** Canonical rules/skills/commands with adapters for **Cursor**, **Codex**, **Antigravity**, and **Claude Code**. |
| Orchestration procedures | **Implemented as host-executed guidance:** `/b3-ship`, `/b3-research-ship`, and review-loop procedures run inside the active host; B3 is **not** a standalone agent scheduler. |
| Context/cost discipline | **Implemented statically only:** Static context budgets, typed TOML preferences & adaptive model routing ([`configuration.md`](configuration.md)), delta/context routing, and risk-based dispatch; **runtime token/cost savings remain unmeasured**. |
| Agent runtime API | **Not implemented:** Model sessions, model API calls, tool-use loops, and standalone scheduling remain responsibilities of the active host. |
| Real-host acceptance & telemetry | **Not verified at runtime:** Live slash-command/skill discovery, end-to-end host outcomes, cross-host runtime cost telemetry, and alternative runtime integrations require explicit live validation; do not infer them from filesystem, adapter-sync, or CLI tests. |

## Delivery phases

### Phase 1 (P0) — Repository stabilization & multi-host baseline reliability (in progress)

**Build:** Keep the native Rust `b3` core, adapter sync, and existing host workflows reliable. Maintain clean CI across `ubuntu-latest`, `macos-latest`, and `windows-latest` and resolve regressions before adding architectural scope. Define a reproducible XS/S/M/L/XL/XXL task corpus with frozen starting Git SHAs, acceptance criteria, and allowed scope.

**Exit evidence:** Green cross-OS CI and reproducible corpus task specifications ready for paired baseline runs across active hosts.

### Phase 2 — Multi-host dogfooding (Cursor, Codex, Antigravity + Claude Code parity) (planned)

**Build:** Exercise daily B3 workflows (`/b3-plan`, `/b3-implement`, `/b3-debug`, `/b3-review`, `/b3-review-loop`, `/b3-ship`, `/b3-research-ship`, PR commands) on real tasks across **Cursor**, **Codex**, and **Antigravity**, while maintaining parity for the supported **Claude Code** adapter. Capture real-host friction, discovery mismatches, and adapter gaps.

**Exit evidence:** Recorded real-host session notes and verified adapter fixes grounded in observed host behavior rather than static file checks alone.

### Phase 3 — Cross-host baseline measurement (planned)

**Build:** Capture a *same-host, same-model, same-task* baseline with and without B3 on the XS..XXL corpus across active hosts where telemetry is accessible.

**Exit evidence:** Recorded inputs, model/settings, starting SHAs, completed acceptance criteria, actual token/billed usage when exposed (`UNKNOWN` when telemetry is unavailable), wall-clock latency, retries, review/fixer passes, and human interventions. Separate observed telemetry from static byte approximations.

### Phase 4 (P1) — Cost-aware efficiency optimization (planned)

**Build:** Optimize **verified work per total execution cost**—dispatch/no-dispatch thresholds, minimum-context handoffs, delta-first review, verified cache reuse, and stopping conditions. Keep cheap tasks inline, isolate only when risk requires, and use deterministic `b3` checks instead of model calls where equivalent.

**Exit evidence:** Paired end-to-end comparison shows lower *total execution cost per verified completed task* (or better verified outcomes at justified cost) without increasing false `PASS`, security failures, or human recovery. Simplify or remove optimizations that cost more than they save. Report by task size; zero invented percentage targets.

### Phase 5 — Production readiness & versioned release hardening (planned)

**Build:** Harden versioned `v*.*.*` binary releases, cross-target checksum/bootstrap verification, upgrade/rollback safety, adapter sync ergonomics, and regression gates so B3 operates dependably as a released multi-host engineering harness.

**Exit evidence:** Reproducible tagged release verification across all supported target triples and clean install/upgrade smoke evidence.

### Phase 6 (P2–P3, conditional) — Minimal external CLI runtime boundary & selective standalone runtime

**Trigger (P2 — Minimal external runtime boundary):** A real external coding-agent CLI/runtime must execute a B3 workflow outside existing host adapters. Do not implement ahead of an actual integration need.

- **Build (P2):** Specify the smallest capability-oriented boundary the workflow needs (e.g., launch task, observe events/status, cancel, optional resume, optional usage reports) with explicit unsupported-capability reporting, validated against a public mock/fake adapter. Keep `src/guard/` and canonical guidance independent of runtime-specific APIs, credentials, and model identifiers.
- **Exit evidence (P2):** One existing workflow completes unchanged via the mock adapter with correct failure/permission handling; do not claim real-runtime compatibility from mocks alone.

**Trigger (P3 — Selective host validation & optional standalone runtime):** A permitted external runtime is available in an authorized environment, or existing hosts/adapters fail a demonstrated, measured requirement.

- **Build (P3):** Run the same task corpus and evidence contracts on the alternative runtime, keeping sensitive operational adapters in the authorized environment and recording only generic lessons publicly. Build a standalone model/tool/session runtime **only** when existing hosts and adapters cannot meet a demonstrated need and measured benefits exceed operational/security maintenance cost (optional decision, **not** a committed roadmap phase).
- **Exit evidence (P3):** Real-host acceptance demonstrates correct dispatch, tool permissions, cancel/resume where supported, usage visibility, and verified outcomes with measured cost. An alternative host becomes supported only after evidence, not by declaration.

## Evaluation and decision rules

- Compare **host without B3** vs. **same host with B3** first; then compare alternative runtime integrations separately. Do not attribute differences between distinct models to the harness.
- Capture all orchestrator, builder, reviewer, fixer, retry, verification, and integration overhead. Core indicators: verified completion, total tokens/usage, cost per verified completed task, wall-clock latency, defect/regression rate, and human intervention count.
- If usage is unavailable, report `UNKNOWN` and measure observable proxies separately; static character-to-token estimates are not billed token measurements.
- Treat quality and security as constraints. A faster or cheaper unverified result is not a win.
- Prefer removing duplicated guard paths or redundant prompts to adding new frameworks. A single observed incident does not justify a permanent universal rule.
- Do not publish proprietary CLI specs, credentials, endpoints, source code, usage logs, or company-specific adapters in this repository.

**Measurement details:** [evaluation.md](evaluation.md). **Governing principles:** [engineering-philosophy.md](engineering-philosophy.md). **Current maturity:** [system-lifecycle.md](system-lifecycle.md).
