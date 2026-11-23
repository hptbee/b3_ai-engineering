# Subagent dispatch naming (load only at spawn)

This is an on-demand contract for B3 orchestrators, **not** a global rule. Read once only when dispatching; do not copy it into each subagent brief.

- **Canonical roles:** Keep `agents/b3-*.md` filename stems and YAML `name:` stable (for example `b3-reviewer`, `b3-fixer`, `b3-security-reviewer`, `b3-architecture-reviewer`, `b3-performance-reviewer`).
- **Logical aliases:** Prefer `b3-impl-<task-id>` (e.g. `b3-impl-t002`) for implementation and `b3-research-<slug>` for research. Use lowercase ASCII kebab-case and a stable, unique task key; shorten long slugs deterministically if the host imposes a name limit, without collisions.
- **Host fallback:** Request the logical alias as a spawn/display name **only if the host API supports custom names**. Never pass unsupported `Role`/display fields or block dispatch because of naming. A host-generated name is acceptable.
- **Resume:** Keep the logical alias separate from the **host-returned agent ID**, when available. Store that ID in run state and resume by ID, not by alias. If there is no resumable ID, use a fresh agent (or record the existing single-agent independence limitation).
- **Scope:** Apply this convention to B3 subagent identifiers, not ordinary prose, application runtime workers, legacy `.b3/autodev/` checkpoints, or historical decision records. Runtime behavior and reviewer independence take priority over cosmetic naming.
