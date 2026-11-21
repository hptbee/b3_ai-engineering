---
name: research-engineering-patterns
description: >
  Use when discovering, comparing, or adapting engineering patterns from
  external repositories, docs, papers, or community sources into this
  personal system. Use when asked to research a repo, extract a pattern,
  decide whether to adopt a method, or record provenance. Do not use for
  ordinary product implementation, local debugging, or copying third-party
  skills verbatim into `.cursor/skills/`.
---

# Research engineering patterns

Research inputs are not the system. The method is: understand, compare, adapt, personalize, verify, record. Do not aggregate GitHub skill packs.

## When to use

- Adding or improving a skill, rule, or workflow based on outside material
- Comparing two or more ways to do the same engineering job
- Deciding adopt vs reject for an external pattern
- Building a provenance record

## When not to use

- Implementing a bounded feature that only needs the stack’s official docs
- Local debugging or verification of a product change
- Requests to “copy this repo’s skills into ours”
- Company or employer playbook import

Near miss: “read the React docs to implement this component” → use official docs in the product work, not this research skill. “Should we adopt this public React skill pack?” → this skill.

## Procedure

Follow `docs/research-methodology.md` end to end:

1. Bound the question.
2. Collect and classify sources honestly.
3. Compare, extract, evaluate fit for a portable personal system.
4. Adapt or reject — rewrite; never paste third-party skill packs.
5. Verify against official docs or a real task, or mark `UNKNOWN / INCOMPLETE`.
6. Record provenance under `research/` using the methodology template.

Do not promote into `knowledge/`, skills, or rules until a decision is recorded (`docs/system-lifecycle.md`).

## Progressive disclosure

- Method, store map, and provenance template: `docs/research-methodology.md`
- Stores index: `research/README.md`
- Knowledge vs reference vs research: `docs/knowledge-system.md`
- Constraint: `rules/evidence-and-provenance.md`

## Verification

Research is verified when adapt/reject is explicit and a check against an official spec or a real task was done **or** the gap is marked `UNKNOWN / INCOMPLETE`.

Not verified: “stars are high”, “the repo looks complete”, “we copied it”.

## Failure handling

- Source unavailable → INCOMPLETE; do not reconstruct from memory as if cited
- Single low-authority source → do not promote to a rule; at most a candidate note
- Pattern is host-specific → extract the portable part or reject; never place it in core skills
- User asks to copy verbatim → refuse the copy, offer adapted synthesis instead
