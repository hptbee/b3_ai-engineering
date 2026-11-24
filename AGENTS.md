# AGENTS.md

Personal AI Engineering System with a **host-neutral canonical core** (`rules/`, `skills/`, `commands/`, `agents/`, `workflows/`, `review-loop/`) and thin adapters for **Cursor**, **Codex**, **Claude Code**, and **Antigravity**. Load the smallest relevant slice — never load the whole repository.

## Canonical map

| Need | Canonical location | When |
| --- | --- | --- |
| Always-on | `AGENTS.md`; `rules/*.md` | Every session |
| Methods | `skills/<cat>/<name>/SKILL.md` | Description-driven or explicit |
| Actions | `commands/*.md`; `adapters/command-skills/` | `/b3-plan` `/b3-implement` `/b3-debug` `/b3-review` `/b3-verify` `/b3-review-loop` `/b3-ship` `/b3-research-ship` |
| Roles | `agents/*.md` | `b3-reviewer`, `b3-fixer`, `b3-{security,architecture,performance}-reviewer` |
| Default flow | `workflows/feature-implementation.md` | Single-stage feature work |
| Full lifecycle | `workflows/ship.md`; `workflows/research-ship.md` | `/b3-ship`; `/b3-research-ship` (research-first) |
| Review loop | `review-loop/strategy.md` (`spec.md` contract) | `/b3-review-loop` |
| Templates | `workflows/references/pr-template.md`; `skills/engineering/code-review/references/review-template.md` | PRs; standalone `/b3-review` & PR comments |
| Docs / Evals | `docs/`, `research/`, `evals/` | Standards, provenance, fixtures |
| Personal / Adapters | `knowledge/personal/`, `adapters/` | Background (non-rule); host wiring |

Loop (`docs/architecture.md`; conflicts: `docs/precedence.md`): `Knowledge → Skills (Rules) → Commands/Workflows → Agents → Verification/Review Loop → Lessons → Knowledge`. No `profiles/`.

## Operating constraints

1. Apply `rules/` via `docs/precedence.md`; preference never silently wins.
2. Load smallest relevant skill; keep handoffs/replies compact.
3. Classify claims: official spec, established practice, community/research, personal experience, preference.
4. Never copy external repos verbatim; log provenance in `research/` (`docs/research-methodology.md`).
5. Tool failure, missing evidence, empty **named review target**, or iteration cap → `UNKNOWN / INCOMPLETE`, never `PASS` (code review: empty diff = empty target; explicit `design-only`: missing approach = `INCOMPLETE`).
6. Never claim unimplemented layers; lessons never auto-become rules (`docs/system-lifecycle.md`).
7. Host link dirs (`.cursor/{skills,commands,agents}`, `.agents/skills`, `.claude/{skills,agents}`, `.codex/skills`) are gitignored links via `adapters/sync-skills.{ps1,sh}` — never edit through them or mix discovery roots.
8. In products, resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, or this repo); never copy `skills/` (`adapters/install-product.{ps1,sh}`).

Host setup: [`adapters/README.md`](adapters/README.md). Layout: `research/decisions/decision-013-host-neutral-multi-host-layout.md`.
