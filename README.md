# b3-ai-engineering

A personal, portable AI-assisted software engineering system for Cursor, Codex, and Claude Code.

This repository is an **evolving engineering operating system** for AI coding agents. It is not complete. Most specialized skills, commands, agents, workflows, and evaluations are not implemented yet. What exists today is the architecture, the standards, a small foundation rule set, and a few core engineering skills.

## Why this exists

AI coding agents are useful only when they operate with:

- durable constraints
- reusable methods
- verification instead of assertion
- a way to learn without turning preference into dogma
- a core that is not locked to one product

This repository is that operating layer. It is personal and portable. It is not a company handbook and not a project-specific rule pack.

## Philosophy

**Portable first.** The core is Markdown, `SKILL.md`, `AGENTS.md`, YAML frontmatter, and occasional scripts. Cursor, Codex, and Claude Code integrations live under `adapters/`.

**Evidence over opinion.** Guidance must say whether it comes from an official specification, established practice, community/research, personal experience, or personal preference.

**Progressive disclosure.** A skill stays small. Details live in `references/`, `scripts/`, and `examples/` and are loaded only when needed.

**Small composable skills.** Prefer `code-review` or `verification` over a single “software-engineering-everything” skill.

**Verification is mandatory.** The default loop is:

```text
Understand → Plan → Implement → Verify → Review → Fix → Re-verify
```

**Research, then adapt.** External repositories are inputs. They are not to be copied wholesale.

## Architecture

```text
Rules
  ↓
Skills
  ↓
Commands / Workflows
  ↓
Agents
  ↓
Verification
  ↓
Review Loop
  ↓
Knowledge / Learning
```

Definitions and examples: [`docs/architecture.md`](docs/architecture.md).

Agent-facing operating notes: [`AGENTS.md`](AGENTS.md).

## Skills

Reusable methods for focused problems. Standard: [`docs/skill-standard.md`](docs/skill-standard.md).

**Present now** (engineering foundation only):

- `skills/engineering/research-engineering-patterns/`
- `skills/engineering/verification/`
- `skills/engineering/problem-solving/`
- `skills/engineering/code-review/`

**Not present yet:** frontend, backend, architecture, UI/UX, security, testing, AI-engineering, and product skills. Those will be researched and written later.

## Rules

Persistent constraints. Standard: [`docs/rule-standard.md`](docs/rule-standard.md).

Foundation rules:

- `rules/engineering-principles.md`
- `rules/verification.md`
- `rules/portability.md`
- `rules/evidence-and-provenance.md`

This is not a large ruleset. Preferences do not belong here until they have earned that status.

## Commands

User-triggered operations such as `research`, `plan`, `implement`, `review`, `verify`.

The command layer is **specified, not implemented**. See [`commands/README.md`](commands/README.md).

## Agents

Specialized roles such as architect, security reviewer, or researcher.

The agent layer is **specified, not implemented**. See [`agents/README.md`](agents/README.md).

## Workflows

Multi-step orchestration across skills, commands, and agents.

The workflow layer is **specified, not implemented**. See [`workflows/README.md`](workflows/README.md).

## Review Loop

Independent review, fix, verify, and re-review, with safeguards against false passes and false convergence.

The loop is **specified**. Runtime reviewers and termination logic are not implemented. See [`docs/review-loop.md`](docs/review-loop.md) and [`review-loop/README.md`](review-loop/README.md).

## Knowledge

Three stores:

- **Stable** — long-lived engineering knowledge
- **Volatile** — versioned, frequently changing technology knowledge
- **Personal** — experience and preference, never auto-promoted to universal rules

See [`docs/knowledge-system.md`](docs/knowledge-system.md) and [`knowledge/`](knowledge/).

## Evaluation

How this system will test itself: skill triggering, skill quality, and review-loop quality.

The evaluation philosophy is documented. Eval cases are **not implemented yet**. See [`docs/evaluation.md`](docs/evaluation.md) and [`evals/README.md`](evals/README.md).

## Platform adapters

```text
Portable Core
     │
     ├── Cursor adapter
     ├── Codex adapter
     └── Claude adapter
```

Adapters stay thin. They map names and file locations; they do not fork the core. See [`adapters/`](adapters/).

## How to use

1. Point an AI coding agent at this repository (or at the portable files you need).
2. Treat [`AGENTS.md`](AGENTS.md) as the operating entry point.
3. Apply `rules/` on every task.
4. Load only the skill that matches the current problem.
5. Verify with evidence. Incomplete checks are incomplete, not passing.
6. Use an adapter only for the host tool’s wiring.

This repository can sit beside a product repo. It should not be copied into a product as a company standard.

## How the system evolves

The intended growth path:

1. Keep the architecture and standards stable.
2. Research external patterns using [`docs/research-methodology.md`](docs/research-methodology.md).
3. Add small skills one domain at a time (frontend, backend, architecture, and so on).
4. Promote only durable constraints into `rules/`.
5. Add commands, agents, and workflows when a repeated need is clear.
6. Implement the review loop and then evaluate it.
7. Record knowledge with provenance. Keep personal notes personal.

The next work is research and deliberate synthesis, not bulk import of public skill packs.
