# Knowledge

Specification: [`docs/knowledge-system.md`](../docs/knowledge-system.md).

**Status:** stores exist; almost no entries yet. Do not fill by scraping.

```text
knowledge  = what the system knows
reference  = material used to perform a task
research   = where conclusions came from
```

| Store | Path | Role |
| --- | --- | --- |
| Stable | `stable/` | Long-lived engineering knowledge |
| Volatile | `volatile/` | Versioned, fast-changing technology knowledge |
| Personal | `personal/` | Reusable lessons and experience — not universal rules |

Personal **profile** (style, preferences) lives in [`../profiles/tung/`](../profiles/tung/engineering-style.md), not here. Background stack: [`personal/engineering-context.md`](personal/engineering-context.md).

Entries should use the metadata format in the knowledge-system doc. Volatile notes need `last_verified`, `source`, and `version` where they matter. Lessons do not auto-promote to rules.
