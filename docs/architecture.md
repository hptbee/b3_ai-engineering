# Architecture and taxonomy

This document defines the building blocks of the system. It is definitional. Operating instructions for agents live in [`AGENTS.md`](../AGENTS.md). Standards for individual types live in the sibling docs.

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
| **Adapters** | Expose the portable core to Cursor, Codex, or Claude Code. |
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

**Present (minimal).** Four engineering skills exist under `skills/engineering/`. Domain skills (React, APIs, UX, and so on) do not exist yet.

Example:

> Skill: code review — produce evidence-based findings for a change, without running the full review loop.

See [`skill-standard.md`](skill-standard.md).

## Command

**Question:** What action should the agent perform now?

A command is an explicit, user-triggered operation. It selects a workflow or skill and runs it now. Commands are not standing constraints and not long-form knowledge.

**Specified, not implemented.** See [`../commands/README.md`](../commands/README.md).

Example:

> Command: review the current change.

## Agent

**Question:** Who should handle this?

An agent is a specialized role with a narrower mandate than the default coding agent. Roles exist so review and research can be independent of implementation.

**Specified, not implemented.** See [`../agents/README.md`](../agents/README.md).

Example:

> Agent: security reviewer.

## Workflow

**Question:** In what order should things happen?

A workflow orchestrates skills, commands, and agents across multiple steps. It does not replace a skill; it sequences them.

**Specified, not implemented.** See [`../workflows/README.md`](../workflows/README.md).

Example:

> Workflow: feature implementation — understand, plan, implement, verify, review, fix, re-verify.

Until workflow files exist, that sequence is the default operating loop.

## Review Loop

**Question:** Is the implementation actually correct?

The review loop is independent checking plus iterative correction. It is stricter than a single code-review skill: it has scope, iteration limits, stagnation detection, a finding lifecycle, and a ban on treating tool failure as success.

**Specified.** See [`review-loop.md`](review-loop.md). Runtime pieces will live under `review-loop/`.

Example:

> Review → fix → verify → re-review affected areas, then stop when clean or when a termination condition is hit.

## Knowledge

**Question:** What have we learned?

Knowledge is the canonical reusable store of this system — not an instruction to execute. It is split into stable, volatile, and personal stores.

**Present (minimal).** The stores exist. Content is mostly empty except for personal engineering context.

Example:

> Known React rendering performance pattern, recorded with source and last-verified date.

See [`knowledge-system.md`](knowledge-system.md).

## Reference

**Question:** What material does this task need right now?

A reference is supporting material consumed by a skill or workflow. Skill-local references live next to `SKILL.md`. Shared task aids may live under `references/`. References are not canonical system knowledge and not research provenance.

Example:

> `skills/react-performance/references/memoization.md` — opened while applying that skill.

## Research

**Question:** Where did this conclusion come from?

Research is external intake and synthesis **before** knowledge, skills, or rules are created. Stores: `research/sources`, `findings`, `comparisons`, `decisions`, `rejected`.

**Present (empty).** Method: [`research-methodology.md`](research-methodology.md). Layout: [`../research/README.md`](../research/README.md). No research files yet.

## Profile

**Question:** What is the owner’s engineering context?

A profile is personal context (style, preferences, strengths, weaknesses, decision principles). It is not universal engineering truth.

```text
Personal preference  ≠  Engineering rule
```

A profile must never override safety, correctness, explicit project requirements, hard rules, or platform constraints. See [`precedence.md`](precedence.md) and [`../profiles/README.md`](../profiles/README.md).

**Present (placeholders).** `profiles/tung/`.

## Adapter

**Question:** How does this work in Cursor, Codex, or Claude Code?

An adapter maps portable files onto a host tool. It may rename, symlink, or generate host-specific manifests. It must not fork rules or skills.

**Specified (minimal docs).** See [`../adapters/README.md`](../adapters/README.md).

Example:

> Cursor-specific mapping of portable skills to Cursor skill discovery.

## Eval

**Question:** Does this part of the system actually work?

An eval is a test of the AI system itself: activation, capability, safety, and review-loop convergence. It is not an application test suite for a product under development.

**Specified, not implemented.** See [`evaluation.md`](evaluation.md).

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
