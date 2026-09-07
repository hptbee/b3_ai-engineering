# Rule standard

Rules are durable engineering constraints. They answer: **what must always be true?**

This repository starts with a small foundation set in `rules/`. Do not grow that set casually. Most guidance belongs in skills, knowledge, or personal notes.

## Qualities of a good rule

- **Short** — one idea per file or section; readable in a few seconds
- **Explicit** — an agent can tell whether it complied
- **Testable where possible** — evals can construct a should-violate / should-comply case
- **Technology-agnostic** unless the constraint is inherently about a technology
- **Behavioral** — about what the agent may claim or do, not about formatting trivia

A rule that cannot be violated in a meaningful way is not a rule.

## Strength

Not every statement in `rules/` has the same force. Label strength when it is not obvious.

| Strength | Meaning | May be overridden? |
| --- | --- | --- |
| **Hard rule** | Non-negotiable constraint | No, unless the rule itself defines an exception |
| **Strong guideline** | Default that requires a stated reason to skip | Yes, with an explicit reason in the working notes |
| **Personal preference** | Taste. Does not belong in `rules/` | N/A — store under `knowledge/personal/` |

If a “rule” is really a preference (“I like early returns”), put it in personal knowledge. It may later become a project convention in a product repo. It does not become a universal hard rule here.

## What belongs in rules/

Good candidates:

- Do not claim verification that did not happen
- Do not treat tool failure as PASS
- Do not present personal preference as specification
- Keep the core portable; put host wiring in adapters
- Record provenance for adapted external patterns

Poor candidates:

- Framework style opinions that change yearly
- Entire review checklists
- API design tutorials
- “Always use technology X”

Those are skills, volatile knowledge, or personal notes.

## File conventions

- One concern per file, kebab-case names, Markdown
- Lead with the constraint, then a short rationale
- Link to the skill or doc that explains *how*, if needed
- Do not duplicate the full skill text

Example shape:

```markdown
# Verification

Hard rule: Never claim a check passed unless that check was actually executed.

If the check could not be run, report UNKNOWN / INCOMPLETE.
```

## Promotion path

```text
Personal note  →  strong guideline  →  hard rule
```

Promote only when the constraint has failed in real use (or would cause false success) and remains true across projects and hosts. Demote or delete rules that have become skills, stale, or overly specific.

## Interaction with other layers

- Skills must not contradict hard rules.
- Commands and workflows cannot waive hard rules.
- Adapters cannot rewrite rule meaning.
- Knowledge never silently upgrades into a rule.
