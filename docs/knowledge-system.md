# Knowledge system

Knowledge is the **canonical reusable knowledge** of this personal AI system. It is not a rule, skill, command, research log, or task aid. It answers: **what does the system know?**

```text
knowledge  = what the system knows
reference  = material used to perform a task
research   = where conclusions came from
```

These are not interchangeable. Do not file a GitHub README in `knowledge/` and call it learned. Do not file a skill checklist in `knowledge/` because it is convenient.

Create stores under `knowledge/` when their first real entry exists. Do not fill
them by scraping the internet during unrelated work.

## Categories

```text
knowledge/
├── stable/
├── volatile/
└── personal/
```

### Stable

Long-lived engineering knowledge. Slow to change; high reuse across projects and years.

Examples:

- HTTP semantics
- SOLID
- DDD principles
- database fundamentals
- distributed-systems fundamentals

Stable entries still need sources. “Long-lived” is not “unverified”.

### Volatile

Technology-specific knowledge that changes often. Do not treat a 2022 React note as current without a date.

Examples:

- React, Next.js, TypeScript, Node.js
- Cursor, Codex, Claude Code
- Azure, Cloudflare

Volatile entries should include, where appropriate:

```yaml
last_verified:
source:
version:
```

If `last_verified` is old relative to the technology’s release cadence, treat the entry as a hint to re-verify, not as fact.

### Personal

The owner’s engineering experience and **reusable lessons** — still not universal.

Examples:

- recurring mistakes (as lessons, not rules)
- preferred review style that survived real projects
- lessons from real work that are not yet (and may never be) rules

Personal knowledge must **not** automatically become a rule. Promotion follows [`system-lifecycle.md`](system-lifecycle.md) and [`rule-standard.md`](rule-standard.md).

**Profile vs personal knowledge:** a future `profiles/` entry is who the owner is
and how they prefer to work. `knowledge/personal/` is reusable content with
provenance. Background stack notes: `knowledge/personal/engineering-context.md`.
Preferences that are only taste stay in a profile rather than becoming a rule.

## Knowledge vs references vs Research

| Store | Role | Example |
| --- | --- | --- |
| `knowledge/` | Canonical facts and lessons the system may cite later | “React effects: official pattern, last verified …” |
| Skill `references/` | Material **used while performing a task** | `.cursor/skills/frontend/react-performance/references/checklist.md` |
| `research/` | Intake: sources, findings, comparisons, decisions, rejected, validation | A comparison of two public review-loop designs |

Skill-local layout (when that skill exists):

```text
.cursor/skills/frontend/react-performance/
├── SKILL.md
└── references/
    └── checklist.md
```

Create a shared task-aid location only when a real aid serves multiple skills.
Provenance of *why* we believe something lives in `research/`, then a distilled
entry may be promoted into `knowledge/`.

## Metadata

Recommended YAML frontmatter (or an equivalent header) for knowledge entries:

```yaml
topic:
type:
source:
authority:
verified:
last_verified:
applies_to:
confidence:
```

| Field | Intent |
| --- | --- |
| `topic` | Stable slug |
| `type` | e.g. `technical-pattern`, `concept`, `lesson`, `preference` |
| `source` | `official`, `established-practice`, `community`, `research`, `personal-experience` |
| `authority` | `high`, `medium`, `low`, or `personal` |
| `verified` | Whether someone actually checked it |
| `last_verified` | ISO date |
| `applies_to` | Technologies, layers, or contexts |
| `confidence` | How strongly to trust it in a decision |

Example (technical, official):

```yaml
topic: react-effects
type: technical-pattern
source: official
authority: high
verified: true
last_verified: 2026-09-07
applies_to:
  - react
  - typescript
confidence: high
```

Example (personal):

```yaml
topic: review-style
type: preference
source: personal-experience
authority: personal
verified: false
last_verified: 2026-09-07
applies_to:
  - code-review
confidence: medium
```

For personal experience, `source: personal-experience` and `authority: personal` are required so agents cannot launder taste into specification.

## How agents should use knowledge

1. Prefer a relevant skill for *how*; use knowledge for *facts and lessons*.
2. State the authority class when the knowledge affects a design choice.
3. If volatile knowledge is stale or unverified, re-check official docs.
4. If only personal knowledge or profile applies, label the recommendation as personal.
5. Do not copy product or employer architecture into this repository.
6. Do not let knowledge outrank [`precedence.md`](precedence.md).

## Provenance

When an entry is adapted from research, the trail lives in `research/` (source → finding → decision). The knowledge page should point at that decision, not paste the external skill. Method: [`research-methodology.md`](research-methodology.md).
