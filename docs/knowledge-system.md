# Knowledge system

Knowledge is reusable material the agent may cite. It is not a rule, skill, or command. It answers: **what have we learned?**

Stores live under `knowledge/`. Most entries do not exist yet. Do not fill these stores by scraping the internet during unrelated work.

## Categories

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

The owner’s engineering experience and preferences. Useful, local, and **not universal**.

Examples:

- preferred architecture patterns
- recurring mistakes
- preferred review style
- lessons from real projects
- personal productivity patterns

Personal knowledge must **not** automatically become a rule. Promotion follows [`rule-standard.md`](rule-standard.md).

A starting context file lives at `knowledge/personal/engineering-context.md`. It records background; it does not prescribe architecture for every project.

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
4. If only personal knowledge applies, label the recommendation as personal.
5. Do not copy product or employer architecture into this repository.

## Provenance

When an entry is adapted from research, record source, what changed, and whether it was adopted. The research method is in [`research-methodology.md`](research-methodology.md).
