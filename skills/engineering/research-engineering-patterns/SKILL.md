---
name: research-engineering-patterns
description: >
  Use when discovering, comparing, or adapting engineering patterns from
  external repositories, docs, papers, or community sources into this
  personal system. Use when asked to research a repo, extract a pattern,
  decide whether to adopt a method, or record provenance. Do not use for
  ordinary product implementation, local debugging, or copying third-party
  skills verbatim into skills/.
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

Follow `docs/research-methodology.md`. Summary:

```text
Discover → Collect → Classify → Compare → Extract
→ Evaluate → Adapt → Personalize → Verify → Record provenance
```

1. **Name the question** so discovery stays bounded.
2. **Collect** links, dates, and short notes — not whole trees.
3. **Classify authority** (official, established practice, community, personal).
4. **Compare** at least two sources unless the claim is a primary specification.
5. **Extract** the pattern and the problem it solves, independent of the source’s file layout.
6. **Evaluate** fit for a personal, portable system. Discard host lock-in and company process.
7. **Adapt** into this taxonomy (rule vs skill vs knowledge vs adapter). Rewrite; do not paste.
8. **Personalize** with `authority: personal` when the change is taste or local experience.
9. **Verify** against official docs or a real task. README quality is not evidence.
10. **Record provenance** using the block below, in `research/` — not in `knowledge/` or skill `references/` until a decision promotes it.

## Provenance block

```text
Source:
Pattern:
Why it is useful:
What problem it solves:
What we changed:
Why we changed it:
Adopted / rejected:
```

| Kind | Store |
| --- | --- |
| What externals say | `research/sources/` |
| Extracted patterns | `research/findings/` |
| Multiple approaches | `research/comparisons/` |
| Adopt / modify | `research/decisions/` |
| Intentionally not adopted | `research/rejected/` |

Do not paste the source skill. After a decision, rewrite into `knowledge/` then skills/rules/workflows (`docs/system-lifecycle.md`).

## Progressive disclosure

- Stores: `research/README.md`
- Method: `docs/research-methodology.md`
- Knowledge vs reference vs research: `docs/knowledge-system.md`
- Constraint: `rules/evidence-and-provenance.md`

Open those only if this file is not enough for the current question.

## Verification

Research is verified when:

- the pattern is classified honestly
- adapt/reject is explicit
- a check against an official spec or a real task was done **or** the gap is marked `UNKNOWN / INCOMPLETE`

Not verified: “stars are high”, “the repo looks complete”, “we copied it”.

## Failure handling

- Source unavailable → INCOMPLETE; do not reconstruct from memory as if cited
- Single low-authority source → do not promote to a rule; at most a candidate note
- Pattern is host-specific → extract the portable part or reject; never place it in core skills
- User asks to copy verbatim → refuse the copy, offer adapted synthesis instead
