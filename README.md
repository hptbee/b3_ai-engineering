# b3-ai-engineering

A personal AI-assisted software engineering system. **Cursor is the first host.** The conceptual core (Agent Skills, rules, review-loop, evals, research) stays portable; Codex and Claude adapters map from this repo later.

This is an **evolving** operating layer for AI coding agents. It is not a company handbook.

## Repository layout

```text
b3-ai-engineering/
├── AGENTS.md                 Always-on map (Cursor reads this)
├── README.md                 Human-facing entry
├── .cursor/
│   ├── rules/                Cursor rule activation (.mdc → portable rules/)
│   ├── skills/               Canonical skills (Agent Skills SKILL.md)
│   ├── commands/             User-facing / actions
│   └── agents/               Reviewer / fixer subagents
├── rules/                    Portable rule bodies (source of meaning)
├── workflows/                Default product sequence
├── review-loop/              Spec + orchestration procedure
├── knowledge/                Reusable internal knowledge
├── research/                 Provenance
├── evals/                    Fixtures (not a runner)
├── adapters/                 Other-host mapping + export helper
├── scripts/                  Repository tooling
└── docs/                     Architecture, standards, contracts
```

Catalogs: [`.cursor/skills/README.md`](.cursor/skills/README.md), [`docs/architecture.md`](docs/architecture.md). What Cursor loads: [`AGENTS.md`](AGENTS.md).

## Why it exists

Agents are useful when they have durable constraints, reusable methods, verification instead of assertion, a way to learn without turning preference into dogma, and a core whose **meaning** is not rewritten per product.

## Cursor first, portable meaning

Skills are Agent Skills (`SKILL.md`) stored where Cursor discovers them. Rule **bodies** stay in `rules/*.md` so other hosts can read them without parsing `.mdc`. Cursor activation is `.cursor/rules/*.mdc` (`@`-includes the bodies). Commands and agents are Cursor-native so `/review` and independent subagents work without a setup script.

Evidence over opinion. Progressive disclosure. Small composable skills. Research, then adapt — do not copy skill packs.

## Architecture

Definitions: [`docs/architecture.md`](docs/architecture.md). Operating notes: [`AGENTS.md`](AGENTS.md). Conflicts: [`docs/precedence.md`](docs/precedence.md).

```text
Rules constrain → Skills provide methods → Commands start work
 → Agents isolate roles → Verification / review-loop check
 → Lessons → Knowledge
```

**Profiles** add personal context and are not created yet (`knowledge/personal/` holds background). **Adapters** export to Codex/Claude; they must not fork meaning.

## Research → knowledge → skills

```text
External sources → research/ → knowledge/ → skills / rules / workflows
```

`research/` is intake plus `validation/` evidence. `knowledge/` is what the system knows. Skill `references/` are task aids. Method: [`docs/research-methodology.md`](docs/research-methodology.md). Evolution: [`docs/system-lifecycle.md`](docs/system-lifecycle.md). Lessons do **not** automatically become rules.

## Review loop

Specified in [`review-loop/spec.md`](review-loop/spec.md). Orchestration: [`review-loop/strategy.md`](review-loop/strategy.md). Invoke: [`.cursor/commands/review-loop.md`](.cursor/commands/review-loop.md). Host model slots: `review-loop/models.md`.

## Evaluation

Activation fixtures live under `evals/`. Automated runner deferred. Layout: [`docs/evaluation.md`](docs/evaluation.md).

## Personal profile

Background: [`knowledge/personal/engineering-context.md`](knowledge/personal/engineering-context.md). A `profiles/` directory is **not created** until Tùng records it.

```text
Personal preference  ≠  Engineering rule
```

## Platforms

```text
Portable meaning  →  .cursor/ (this repo)  →  Cursor
                  →  adapters/ (Codex, Claude) when those hosts are used
```

## Current maturity

| Area | Status |
| --- | --- |
| Architecture, standards, precedence, lifecycle | Present |
| Foundation rules + Cursor `.mdc` activation | Present |
| Engineering + domain skills | Present (see `.cursor/skills/README.md`) |
| Commands, agents | Present (Cursor-native, thin) |
| Eval fixtures | Present; runner deferred |
| Review-loop orchestration | Present (agent procedure; not a host plugin) |
| Profile files | Not created (`knowledge/personal/` holds background) |
| Codex / Claude trees | Not committed; export helper only |

**Present rules:** `engineering-principles`, `verification`, `portability`, `evidence-and-provenance`, `simplest-correct`.
