# b3-ai-engineering

A personal, portable AI-assisted software engineering system for Cursor, Codex, and Claude Code.

This is an **evolving** operating layer for AI coding agents. It is not a company handbook. Domain skills exist for the first-class stack. Review-loop **orchestration** lives under `review-loop/` (agent procedure, not a host plugin).

## Why it exists

Agents are useful when they have durable constraints, reusable methods, verification instead of assertion, a way to learn without turning preference into dogma, and a core that is not locked to one product.

## Portable first

The core is Markdown, `SKILL.md`, `AGENTS.md`, YAML frontmatter, and occasional scripts. Cursor, Codex, and Claude Code integrations live under `adapters/` and must stay thin.

Evidence over opinion. Progressive disclosure. Small composable skills. Research, then adapt — do not copy skill packs.

## Architecture

Conceptual feedback loop, not a strict pipeline. Definitions: [`docs/architecture.md`](docs/architecture.md). Operating notes: [`AGENTS.md`](AGENTS.md). Conflicts: [`docs/precedence.md`](docs/precedence.md).

```text
                         ┌──────────────┐
                         │  Knowledge   │
                         └──────┬───────┘
                                ↓
┌──────────┐              ┌──────────────┐
│  Rules   │─────────────→│   Skills     │
└──────────┘              └──────┬───────┘
                                 ↓
                       ┌──────────────────┐
                       │ Commands /       │
                       │ Workflows        │
                       └────────┬─────────┘
                                ↓
                          ┌───────────┐
                          │  Agents   │
                          └─────┬─────┘
                                ↓
                    ┌─────────────────────┐
                    │ Verification /      │
                    │ Review Loop         │
                    └────────┬──────────┘
                               ↓
                       Lessons Learned  →  Knowledge
```

Rules constrain. Skills provide methods. Commands start work. Workflows sequence it. Agents specialize roles. Verification supplies evidence. The review loop independently re-checks. Knowledge feeds the loop and receives lessons. **Profiles** add personal context. **Adapters** expose the core to a host tool.

## Research → knowledge → skills

```text
External sources → research/ → knowledge/ → skills / rules / workflows
```

`research/` is intake (sources, findings, comparisons, decisions, rejected). `knowledge/` is what the system knows. Skill `references/` are task aids. Method: [`docs/research-methodology.md`](docs/research-methodology.md). Evolution and promotion: [`docs/system-lifecycle.md`](docs/system-lifecycle.md). Lessons do **not** automatically become rules.

## Review loop

Specified in [`docs/review-loop.md`](docs/review-loop.md): finding lifecycle, severity ≠ confidence, no fake PASS on empty diffs, tool failure, stagnation, or iteration limits. One-shot orchestration: [`commands/review-loop.md`](commands/review-loop.md) → [`review-loop/strategy.md`](review-loop/strategy.md). Adaptive sizing and unit loops for large PRs. Host model mapping is in `review-loop/models.md` + `adapters/`.

## Evaluation

Activation fixtures exist under `evals/`. Automated runner deferred. Layout: [`docs/evaluation.md`](docs/evaluation.md).

## Personal profile

[`profiles/tung/`](profiles/tung/engineering-style.md) is personal engineering context.

```text
Personal preference  ≠  Engineering rule
```

The profile never overrides security, correctness, project requirements, hard rules, or platform constraints.

## Platforms

```text
Portable Core → Cursor | Codex | Claude Code   (via adapters/)
```

## Current maturity

| Area | Status |
| --- | --- |
| Architecture, standards, precedence, lifecycle | Present |
| Foundation rules + `simplest-correct` | Present |
| Engineering + domain skills | Present (see `skills/README.md`) |
| Commands, agents, workflows | Present (thin) |
| Eval fixtures | Present; runner deferred |
| Review-loop orchestration | Present (agent procedure; not a host plugin) |
| Profile files | Placeholders |

**Present rules:** `engineering-principles`, `verification`, `portability`, `evidence-and-provenance`, `simplest-correct`.
