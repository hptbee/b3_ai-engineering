# Knowledge

Specification: [`docs/knowledge-system.md`](../docs/knowledge-system.md).

**Status:** one personal engineering-context entry exists. Create stable or volatile
stores only when their first real entry is promoted; do not fill them by scraping.

```text
knowledge  = what the system knows
reference  = material used to perform a task
research   = where conclusions came from
```

| Store | Path | Role |
| --- | --- | --- |
| Stable | `stable/` (when needed) | Long-lived engineering knowledge |
| Volatile | `volatile/` (when needed) | Versioned, fast-changing technology knowledge |
| Personal | `personal/` | Reusable lessons and experience — not universal rules |

Personal **profile** content is deferred until Tùng records it. Background stack:
[`personal/engineering-context.md`](personal/engineering-context.md).

Entries should use the metadata format in the knowledge-system doc. Volatile notes need `last_verified`, `source`, and `version` where they matter. Lessons do not auto-promote to rules.
