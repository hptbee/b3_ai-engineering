# b3-ai-engineering

A personal, portable AI-assisted software engineering system for Cursor, Codex, and Claude Code.

This is an **evolving** operating layer for AI coding agents. It is not a company handbook and not a finished catalog of skills. Most specialized skills, commands, agents, workflows, evals, and the review-loop runtime are **not implemented**.

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

Specified in [`docs/review-loop.md`](docs/review-loop.md): finding lifecycle, severity ≠ confidence, no fake PASS on empty diffs, tool failure, stagnation, or iteration limits. Runtime under `review-loop/` is **not implemented**.

## Evaluation

Framework only: activation, capability, safety, and convergence. Layout: [`docs/evaluation.md`](docs/evaluation.md). No eval cases yet.

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
| Foundation rules (4) | Present |
| Foundation skills (4, engineering) | Present |
| Research stores, profile placeholders | Present (empty / placeholders) |
| Commands, agents, workflows | Specified, not implemented |
| Review-loop runtime, evals | Specified, not implemented |
| Domain skills (React, APIs, UX, …) | Not started — next phase is research |

**Present skills:** `research-engineering-patterns`, `verification`, `problem-solving`, `code-review`.

**Present rules:** `engineering-principles`, `verification`, `portability`, `evidence-and-provenance`.
