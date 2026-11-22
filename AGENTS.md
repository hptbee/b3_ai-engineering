# AGENTS.md

Personal AI Engineering System with a **host-neutral canonical core** (`rules/`, `skills/`, `commands/`, `agents/`, `workflows/`, `review-loop/`) and thin adapters for **Cursor**, **Codex**, **Claude Code**, and **Antigravity**. Load the smallest relevant slice — never load the whole repository.

## Canonical map

| Need | Canonical location | When |
| --- | --- | --- |
| Always-on constraints | `AGENTS.md`; `rules/*.md` | Every session |
| Methods | `skills/<category>/<name>/SKILL.md` | Description-driven or explicit invocation |
| User actions | `commands/*.md` (and `adapters/command-skills/`) | `/plan` `/implement` `/debug` `/review` `/verify` `/review-loop` `/ship` |
| Isolated roles | `agents/*.md` | Reviewer, fixer, security, architecture, performance reviewers |
| Default sequence | `workflows/feature-implementation.md` | Single-stage feature work |
| Full lifecycle | `workflows/ship.md` | `/ship`: preflight through build, verify, review, commit, resume |
| Review loop | `review-loop/strategy.md` (`spec.md` contract) | `/review-loop` |
| Docs / Provenance / Evals | `docs/`, `research/`, `evals/` | Definitions, external intake, system fixtures |
| Personal context / Adapters | `knowledge/personal/`, `adapters/` | Background (never overrides rules); host wiring |

Loop (`docs/architecture.md`; conflicts: `docs/precedence.md`): `Knowledge → Skills (Rules) → Commands/Workflows → Agents → Verification/Review Loop → Lessons → Knowledge`. No `profiles/` directory.

## Operating constraints

1. Apply `rules/` with `docs/precedence.md`; personal preference never silently wins.
2. Load the smallest relevant skill; keep subagent handoffs and replies compact.
3. Classify claims: official spec, established practice, community/research, personal experience, preference.
4. Never copy external repos verbatim; record provenance in `research/` (`docs/research-methodology.md`).
5. Tool failure, missing evidence, empty **named review target**, or iteration cap → `UNKNOWN / INCOMPLETE`, never `PASS`. For code review, empty diff = empty target; for explicit `design-only` review, missing approach = `INCOMPLETE`, absent diff is not.
6. Never claim unimplemented layers exist; lessons do not auto-become rules (`docs/system-lifecycle.md`).
7. Host link dirs (`.cursor/{skills,commands,agents}`, `.agents/skills`, `.claude/{skills,agents}`, `.codex/skills`) are gitignored links managed by `adapters/sync-skills.{ps1,sh}` — never edit through them or mix conflicting discovery roots.
8. In product repos, resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, or this repo) and never copy `skills/` into the product (`adapters/install-product.{ps1,sh}`).

Host activation details: [`adapters/README.md`](adapters/README.md). Layout decision: `research/decisions/decision-013-host-neutral-multi-host-layout.md`.
