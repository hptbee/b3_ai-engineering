# Rule standard

Rules are durable engineering constraints. They answer: **what must always be true?**

This repository starts with a small foundation set in `rules/`. Do not grow that set casually. Most guidance belongs in skills, knowledge, profiles, or personal notes.

## Qualities of a good rule

- **Short** — one idea per file or section; readable in a few seconds
- **Explicit** — an agent can tell whether it complied
- **Testable where possible** — evals can construct a should-violate / should-comply case
- **Technology-agnostic** unless the constraint is inherently about a technology
- **Behavioral** — about what the agent may claim or do, not about formatting trivia

A rule that cannot be violated in a meaningful way is not a rule.

## Optional metadata

YAML frontmatter makes precedence and provenance explicit. Fields are **optional**; omit any that add noise. Do not invent a large schema.

```yaml
---
type: rule
strength: hard
scope: global
source: synthesized
authority: high
---
```

### strength

```text
hard
strong
guideline
preference
```

| Value | Meaning | May be overridden? |
| --- | --- | --- |
| `hard` | Non-negotiable constraint | No, except as [`precedence.md`](precedence.md) states (safety, honest user/project conflict handling). Never via preference. |
| `strong` | Default that requires a stated reason to skip | Yes, with an explicit reason |
| `guideline` | Advice; weaker than `strong` | Yes |
| `preference` | Taste | **Does not belong in `rules/`** — use `profiles/` or `knowledge/personal/` |

If a “rule” is really a preference (“I like early returns”), do not file it here.

### scope

Examples (not a closed enum):

```text
global
engineering
frontend
backend
architecture
security
testing
project
```

Prefer `global` unless the constraint is inherently scoped. `project` rules belong in the product repo, not in this personal system.

### source

Examples:

```text
official
research
community
personal-experience
synthesized
project
```

`synthesized` means we adapted more than one input (typical for this repo). `personal-experience` on a rule still cannot silently outrank project requirements.

Other useful optional fields: `authority`, `last_verified`, `applies_to` — same spirit as knowledge metadata. Skip them when they do not help.

## What belongs in rules/

Good candidates:

- Do not claim verification that did not happen
- Do not treat tool failure as PASS
- Do not present personal preference as specification
- Keep meaning portable; Cursor activation is `.cursor/rules/*.mdc`; other-host wiring stays in `adapters/`
- Record provenance for adapted external patterns

Poor candidates:

- Framework style opinions that change yearly
- Entire review checklists
- API design tutorials
- “Always use technology X”

Those are skills, volatile knowledge, or profile notes.

## File conventions

- One concern per file, kebab-case names, Markdown
- Optional frontmatter, then the constraint, then a short rationale
- Link to the skill or doc that explains *how*, if needed
- Do not duplicate the full skill text

Example shape:

```markdown
---
type: rule
strength: hard
scope: global
source: synthesized
authority: high
---

# Verification

Hard rule: Never claim a check passed unless that check was actually executed.

If the check could not be run, report UNKNOWN / INCOMPLETE.
```

## Promotion path

```text
Lesson → Candidate Pattern → Evaluation → Human Approval → Rule / Skill / Knowledge
```

See [`system-lifecycle.md`](system-lifecycle.md). Promote to `hard` only when the constraint has failed in real use (or would cause false success) and remains true across projects and hosts. Demote or delete rules that have become skills, stale, or overly specific.

## Interaction with other layers

- Skills must not contradict hard rules.
- Commands and workflows cannot waive hard rules.
- Adapters cannot rewrite rule meaning.
- Knowledge and profiles never silently upgrade into a rule.
- Full conflict order: [`precedence.md`](precedence.md).
