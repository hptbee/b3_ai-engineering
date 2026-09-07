# Portability

Hard rule: the portable core (`AGENTS.md`, `rules/`, `skills/`, `docs/`, `knowledge/`) must not depend on Cursor, Codex, or Claude Code.

Hard rule: host-specific paths, manifests, hooks, and command IDs belong under `adapters/`. Adapters may map or generate; they may not fork meaning.

Strong guideline: prefer Markdown, `SKILL.md`, YAML frontmatter, and plain shell/Node/Python scripts.

Strong guideline: if a skill cannot be followed without a specific host feature, the skill is not ready — extract the portable method, then adapt.
