# AGENTS.md

Personal AI Engineering System with a **host-neutral canonical core** (`rules/`, `skills/`, `commands/`, `agents/`, `workflows/`, `review-loop/`) and thin adapters (**Cursor**, **Codex**, **Claude Code**, **Antigravity**). Load only the smallest relevant slice.

## Canonical map

| Need | Canonical location | When |
| --- | --- | --- |
| Always-on | `AGENTS.md`; `rules/*.md` | Every session |
| Methods | `skills/<cat>/<name>/SKILL.md` | Description-driven or explicit |
| Actions | `commands/*.md`; `adapters/command-skills/` | `/b3-plan` `/b3-implement` `/b3-debug` `/b3-research` `/b3-audit` `/b3-review` `/b3-refactor` `/b3-verify` `/b3-review-loop` `/b3-ship` `/b3-research-ship` `/b3-pr-resolve` `/b3-pr-reply` `/b3-pr-comment` |
| Roles | `agents/*.md` | `b3-reviewer`, `b3-fixer`, `b3-{security,architecture,performance}-reviewer` |
| Default flow | `workflows/feature-implementation.md` | Single-stage feature work |
| Full lifecycle | `workflows/ship.md`; `workflows/research-ship.md` | `/b3-ship`; `/b3-research-ship` |
| Review loop | `review-loop/strategy.md` (`spec.md` contract) | `/b3-review-loop` |
| Templates | `workflows/references/pr-template.md`; `skills/engineering/code-review/references/review-template.md` | Branch/PR summaries; `/b3-review` & PR comments |
| Docs / Evals | `docs/`, `research/`, `evals/` | Standards, provenance, fixtures |
| Personal / Adapters | `knowledge/personal/`, `adapters/` | Background (non-rule); host wiring |

Loop (`docs/architecture.md`; conflicts: `docs/precedence.md`): `Knowledge → Skills (Rules) → Commands/Workflows → Agents → Verification/Review Loop → Lessons → Knowledge`.

## Operating constraints

1. Apply `rules/` via `docs/precedence.md`; `knowledge/personal/` never overrides hard rules or project policy.
2. Keep handoffs compact; never load files outside active scope.
3. Empty **named review target** (empty diff, or missing approach in explicit `design-only`) or iteration cap → `UNKNOWN / INCOMPLETE`, never `PASS`.
4. Never claim unimplemented layers; lessons never auto-become rules (`docs/system-lifecycle.md`).
5. Generated host paths (`.cursor/{skills,commands,agents,rules}`, `.agents/{skills,skills.json}`, `.claude/{skills,agents}`) are gitignored via `b3 sync` — never edit through links or mix discovery roots.
6. In products, resolve `B3_HOME` (`B3_HOME` env → `.b3/home` → host global fallback → current repo); never copy `skills/` (`b3 install product`).

Host setup: [`adapters/README.md`](adapters/README.md).
