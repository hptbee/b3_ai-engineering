# Reject — Mandatory multi-agent debate and broad autodev pause gates

## Considered

Adopt two mechanisms from heavyweight multi-agent planning workflows into `/autodev`:

1. **Multi-round explorer debate** before coding (launching 3 explorer agents and resuming all 3 to debate findings across rounds into a revised planning pack).
2. **Broad Approval Gate** pausing for user confirmation whenever a plan touches `auth/permissions`, `data model/migration`, `shared/global code`, or `>= 4` work packages, plus per-plan advisory lint overrides and repeated quality-bar checklists.

## Evidence

- [`../../rules/simplest-correct.md`](../../rules/simplest-correct.md) — avoid extra layers and ceremony without a named requirement.
- [`../../docs/precedence.md`](../../docs/precedence.md) — product repo standards outrank personal/system lint taste.
- [`../decisions/decision-010-autonomous-development.md`](../decisions/decision-010-autonomous-development.md) — `/autodev` must stay autonomous through implementation instead of collapsing back into `/plan`.
- Codex / Claude portability constraints — multi-turn resumable parallel debate assumes host subagent resume parity that is not portable across all targets.

## Why rejected as default

- **Multi-round debates amplify cost and over-engineering:** 6+ subagent turns before writing code multiply latency and tend to negotiate speculative layers/abstractions rather than proving concrete defects.
- **Broad approval gates break autonomy:** Most real features touch an auth boundary, schema/DTO, shared type, or `>= 4` small tasks. Stopping for permission on every such plan reduces `/autodev` to `/plan`.
- **Advisory lint overrides & quality-bar boilerplate:** Overriding a product repo's configured linter rules creates pre-existing noise, and repeating global quality bars in every plan bloats context.

## Decision

**REJECT** as `/autodev` defaults.

## Alternative

- Replace multi-round explorer debates with a **1-pass Pre-code Risk Review** on `depth: detailed` (`architecture-reviewer` + `security-reviewer` in `design-only` mode when auth/untrusted input/race applies), adjudicated once by the orchestrator.
- Automatically elevate `auth`/`migration`/`shared`/multi-area work to `depth: detailed`; pause as `BLOCKED` only for genuine business ambiguity, overlapping `initial_dirty_paths`, external authorization (push/merge/deploy/prod data), or unrequested destructive/breaking changes (data-loss drops, weakening authz, breaking public API contracts).
