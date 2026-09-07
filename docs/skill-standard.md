# Skill design standard

Skills are the reusable methods of this system. Each skill solves one focused problem and is loaded only when that problem is present.

This standard applies to every skill. Catalog: [`../.cursor/skills/README.md`](../.cursor/skills/README.md).

## Layout

```text
skill-name/
├── SKILL.md
├── references/     # optional; load on demand
├── scripts/        # optional; run, do not paste
└── examples/       # optional; concrete cases
```

Do not invent extra top-level files inside a skill unless a later standard says otherwise. Empty `references/`, `scripts/`, or `examples/` directories are omitted until they have real content.

## SKILL.md shape

Use YAML frontmatter where the host supports it:

```yaml
---
name: example-skill
description: >
  Clear description of when this skill should be activated
  and what problem it solves. Include should-not-trigger cues.
---
```

`name` is the directory name (kebab-case). `description` is the trigger surface: agents and hosts decide activation from it, so it must be specific.

The body should stay short. Typical sections:

1. When to use / when not to use
2. Procedure (the actual method)
3. Progressive disclosure (what to open next)
4. Verification
5. Failure handling
6. Portability notes (if any)

## Requirements

### Trigger quality

The description and the “when not to use” section must make both sides obvious:

- when the skill **SHOULD** trigger
- when it **SHOULD NOT** trigger

Future evals will classify cases as:

```text
should-trigger
should-not-trigger
near-miss
```

A near-miss is a request that looks related but belongs to a different skill (for example “review this PR for accessibility” vs general `code-review`).

Write descriptions against realistic user phrasing, not only against internal taxonomy names.

### Concise instructions

The main file is the procedure, not the encyclopedia. If a section is growing past what an agent needs on every invocation, move it to `references/`.

### Progressive disclosure

`SKILL.md` tells the agent **when and how** to use supporting material. It does not inline all of it.

- skill `references/` — task aids: checklists, decision tables, longer how-to
- `scripts/` — deterministic helpers (lint parsers, eval runners, report formatters)
- `examples/` — worked cases, including failure cases

The agent should open supporting files only when the current step needs them.

### References (not knowledge, not research)

```text
knowledge  = what the system knows          → knowledge/
reference  = material used to perform a task → this skill’s references/ (or shared references/)
research   = where conclusions came from     → research/
```

Skill-local example (when such a skill exists):

```text
.cursor/skills/frontend/react-performance/
├── SKILL.md
└── references/
    └── checklist.md
```

Prefer pointing at official docs or `knowledge/` entries over restating them. Each substantial reference should make its authority class obvious. Do not park unprocessed GitHub clones in `references/`.

### Scripts

Scripts are for mechanical work the model should not improvise. They must be host-agnostic when possible (plain shell, Node, or Python). Adapters may wrap them; they must not be the only way to apply the skill.

### Examples

Examples show shape, not a mandate to copy output. Include at least one negative or incomplete example when the skill has a known failure mode (for example a review that marked a failed test run as PASS).

### Verification

Every skill that can change or judge a system must say what evidence counts. “Looks correct” is not evidence. If verification cannot be performed, the skill must require an `UNKNOWN / INCOMPLETE` outcome.

### Failure handling

State what to do when:

- required tools are missing
- the repo under change does not fit the skill’s assumptions
- evidence is partial
- the skill is the wrong skill (hand off, do not stretch)

### Portability

Skills are portable core. Do not depend on Cursor rules, Claude hooks, or Codex-only paths. If a host needs a mapping, put it in `adapters/` and keep the skill text host-agnostic.

## What a skill is not

- Not a dump of another repository’s `SKILL.md`
- Not a catch-all “engineering everything” pack
- Not a rule (no standing constraint without a method)
- Not a workflow (no multi-role orchestration)
- Not personal taste presented as industry law (that is a profile or `knowledge/personal/`)
- Not a research source dump (that is `research/sources/`)

## Authoring checklist

Before adding a skill:

- [ ] Name is focused and kebab-case
- [ ] Frontmatter `description` encodes should / should-not trigger
- [ ] Body is concise; extras are in supporting dirs
- [ ] Verification and failure handling are explicit
- [ ] No host-specific coupling
- [ ] No company-specific or project-specific lock-in
- [ ] Provenance recorded in `research/` if the method was adapted from research
- [ ] At least a sketch of `should-trigger` / `should-not-trigger` / `near-miss` cases for later evals
