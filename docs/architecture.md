# Architecture and taxonomy

This document defines the building blocks of the system. It is definitional. Operating instructions for agents live in [`AGENTS.md`](../AGENTS.md). Standards for individual types live in the sibling docs.

## Source vs generated vs documentation

| Kind | What | Where |
| --- | --- | --- |
| **Source (meaning)** | Rule bodies, skills, commands, agents, review-loop, workflows, evals, knowledge | `rules/`, `.cursor/skills/`, `.cursor/commands/`, `.cursor/agents/`, `review-loop/`, `workflows/`, `evals/`, `knowledge/` |
| **Cursor activation** | Host discovery / always-on injection | `.cursor/rules/*.mdc`, native skill/command/agent folders |
| **Documentation** | Explains the system; not configuration | `docs/`, `README.md` |
| **Research** | Provenance; not production config | `research/` |
| **Generated** | Other-host discovery links only | `.agents/skills`, `.claude/skills` via `adapters/sync-skills.sh` (not committed) |

Cursor is the first host. Skills/commands/agents are stored on Cursor discovery paths so a fresh clone works. Format stays portable (Agent Skills, Markdown). Decision: [`../research/decisions/decision-009-cursor-native-layout.md`](../research/decisions/decision-009-cursor-native-layout.md).

The system is evolving. Layers marked **specified** exist as documentation and directories. Layers marked **present** have usable files.

## Feedback-loop model

The system is **not** a strict execution pipeline. The diagram is conceptual: it shows how constraints, methods, action, and learning relate. A given task may enter at a command, a skill, or a review — it does not walk every box.

```text
                         ┌──────────────┐
                         │  Knowledge   │
                         └──────┬───────┘
                                │
                                ↓
┌──────────┐              ┌──────────────┐
│  Rules   │─────────────→│   Skills     │
└──────────┘              └──────┬───────┘
                                 │
                                 ↓
                       ┌──────────────────┐
                       │ Commands /       │
                       │ Workflows        │
                       └────────┬─────────┘
                                │
                                ↓
                          ┌───────────┐
                          │  Agents   │
                          └─────┬─────┘
                                │
                                ↓
                    ┌─────────────────────┐
                    │ Verification /      │
                    │ Review Loop         │
                    └────────┬──────────┘
                               │
                               ↓
                       Lessons Learned
                               │
                               └────────────→ Knowledge
```

Around that loop:

| Piece | Role |
| --- | --- |
| **Rules** | Constrain behavior. What must always be true. |
| **Skills** | Specialized knowledge and methods. How this task should be done. |
| **Commands** | Initiate explicit actions. What to do now. |
| **Workflows** | Orchestrate multiple steps. In what order. |
| **Agents** | Specialized roles. Who should handle this. |
| **Verification** | Evidence that a claim is true, false, or unproven. |
| **Review Loop** | Independent iterative validation. Is the implementation actually correct? |
| **Knowledge** | Feeds the system and receives lessons learned. What we know. |
| **Profiles** | Personal engineering context. Not universal truth and not a rule. |
| **Research** | External intake before knowledge or skills are created. Where conclusions came from. |
| **Adapters** | Map this repo onto other hosts. Cursor consumes `.cursor/` directly. |
| **Evals** | Test whether the system behaves as designed. |

Lessons learned do **not** automatically become rules. Promotion is in [`system-lifecycle.md`](system-lifecycle.md). Conflict resolution is in [`precedence.md`](precedence.md).

## Layer map

```text
Rule          persistent constraint
Skill         reusable method for a focused problem
Command       explicit user-triggered action
Agent         specialized role
Workflow      ordered multi-step orchestration
Review Loop   independent verification and iterative correction
Knowledge     canonical reusable knowledge of this system
Reference     material used to perform a task (usually skill-local)
Research      external intake, findings, comparisons, decisions
Profile       personal engineering context (not a rule)
Adapter       thin host-tool integration
Eval          test of whether the system behaves as designed
```

These types are not interchangeable. In particular:

```text
knowledge  = what the system knows
reference  = material used to perform a task
research   = where conclusions came from
profile    = who the owner is and how they prefer to work
```

## Rule

**Question:** What must always be true?

A rule is a durable constraint on agent behavior. Rules are short, explicit, and preferably testable. They are technology-agnostic unless the constraint is inherently about a technology.

**Present.** Foundation files are in `rules/`.

Example:

> Never claim a test passed unless it was actually executed.

A rule is not a preference, not a tutorial, and not a skill. If the content is a method (“how to review a PR”), it belongs in a skill. If it is optional taste, it belongs in a profile or `knowledge/personal/`.

See [`rule-standard.md`](rule-standard.md).

## Skill

**Question:** How should this task be done?

A skill is a focused, on-demand method. It has a `SKILL.md`, optional `references/`, `scripts/`, and `examples/`, and a description that states when it should and should not trigger.

**Present.** Foundation engineering skills plus domain skills (React, APIs, .NET, Three.js). Catalog: [`../.cursor/skills/README.md`](../.cursor/skills/README.md).

Example:

> Skill: code review — produce evidence-based findings for a change, without running the full review loop.

See [`skill-standard.md`](skill-standard.md).

## Command

**Question:** What action should the agent perform now?

A command is an explicit, user-triggered operation. It selects a workflow or skill and runs it now. Commands are not standing constraints and not long-form knowledge.

**Present (thin).** See [`../.cursor/commands/README.md`](../.cursor/commands/README.md).

Example:

> Command: review the current change.

## Agent

**Question:** Who should handle this?

An agent is a specialized role with a narrower mandate than the default coding agent. Roles exist so review and research can be independent of implementation.

**Present (reviewer, fixer, security, architecture).** See [`../.cursor/agents/README.md`](../.cursor/agents/README.md).

Example:

> Agent: security reviewer.

## Workflow

**Question:** In what order should things happen?

A workflow orchestrates skills, commands, and agents across multiple steps. It does not replace a skill; it sequences them.

**Present (one default sequence).** See [`../workflows/README.md`](../workflows/README.md). Independent review is `review-loop/` + `.cursor/commands/review-loop.md`, not a second workflow file.

Example:

> Workflow: feature implementation — understand, plan, implement, verify, review, fix, re-verify.

The default product sequence is `workflows/feature-implementation.md`.

## Review Loop

**Question:** Is the implementation actually correct?

The review loop is independent checking plus iterative correction. It is stricter than a single code-review skill: it has scope, iteration limits, stagnation detection, a finding lifecycle, and a ban on treating tool failure as success.

**Present (orchestration).** Spec: [`../review-loop/spec.md`](../review-loop/spec.md). Procedure: [`../review-loop/strategy.md`](../review-loop/strategy.md). Trigger: `.cursor/commands/review-loop.md`. This is agent procedure, not a host plugin or eval runner.

Example:

> Size the PR → review → validate → fix → verify → fresh review until the quality gate, non-convergence, or iteration limit.

## Knowledge

**Question:** What have we learned?

Knowledge is the canonical reusable store of this system — not an instruction to execute. It is split into stable, volatile, and personal stores.

**Present (minimal).** Create `stable/` or `volatile/` only when the first real entry exists. Currently: [`../knowledge/personal/engineering-context.md`](../knowledge/personal/engineering-context.md).

Example:

> Known React rendering performance pattern, recorded with source and last-verified date.

See [`knowledge-system.md`](knowledge-system.md).

## Reference

**Question:** What material does this task need right now?

A reference is supporting material consumed by a skill or workflow. Skill-local references live next to `SKILL.md`. Shared task aids may live under `references/`. References are not canonical system knowledge and not research provenance.

Example:

> `.cursor/skills/frontend/react-performance/references/checklist.md` — opened while applying that skill.

## Research

**Question:** Where did this conclusion come from?

Research is external intake and synthesis **before** knowledge, skills, or rules are created. Stores: `research/sources`, `findings`, `comparisons`, `decisions`, `rejected`, `validation`.

**Present.** Method: [`research-methodology.md`](research-methodology.md). Layout: [`../research/README.md`](../research/README.md).

## Profile

**Question:** What is the owner’s engineering context?

A profile is personal context (style, preferences, strengths, weaknesses, decision principles). It is not universal engineering truth.

```text
Personal preference  ≠  Engineering rule
```

A profile must never override safety, correctness, explicit project requirements, hard rules, or platform constraints. See [`precedence.md`](precedence.md). Profile vs personal knowledge: [`knowledge-system.md`](knowledge-system.md).

**Specified (not created).** Do not invent `profiles/` for symmetry. Existing background: [`../knowledge/personal/engineering-context.md`](../knowledge/personal/engineering-context.md).

## Adapter

**Question:** How does this work in Cursor, Codex, or Claude Code?

An adapter maps this repo onto a host tool. Cursor consumes `.cursor/` directly (not generated). Codex/Claude adapters may symlink or generate host-specific manifests. They must not fork rules or skills.

**Present (Cursor native + other-host docs).** See [`../adapters/README.md`](../adapters/README.md).

Example:

> Codex symlink `.agents/skills` → `.cursor/skills`.

## Eval

**Question:** Does this part of the system actually work?

An eval is a test of the AI system itself: activation, capability, safety, and review-loop convergence. It is not an application test suite for a product under development.

**Present (fixtures).** Runner deferred. See [`evaluation.md`](evaluation.md).

Example:

> Test whether the verification skill triggers on “confirm this works” and does not trigger on “explain HTTP caching”.

## What is not a separate type

| Thing | Treat as |
| --- | --- |
| Prompt snippet | Part of a skill, command, or agent — not a top-level type |
| Checklist | Usually a skill reference, sometimes a review-loop reviewer |
| Preference | Profile or `knowledge/personal/` — never a hard rule by default |
| Copied GitHub skill pack | `research/sources/` input, not a first-class object |
| Lesson learned | Candidate only until evaluated and approved |

## Related docs

- Precedence: [`precedence.md`](precedence.md)
- Evolution: [`system-lifecycle.md`](system-lifecycle.md)
