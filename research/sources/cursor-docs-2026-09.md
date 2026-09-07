# Source — Cursor docs (2026-09)

- Retrieved: 2026-09-07
- URLs:
  - https://cursor.com/docs/skills
  - https://cursor.com/docs/rules
  - https://cursor.com/docs/subagents
- Authority: official product documentation
- Used for: decision-009 (Cursor-native layout)

## Facts extracted (not copied)

- Project skills are discovered from `.cursor/skills/` and `.agents/skills/` (plus Claude/Codex compatibility dirs). Repo-root `skills/` is not a discovery path.
- Nested `SKILL.md` trees under a discovery root are valid; identity is the folder that contains `SKILL.md`.
- Project rules must be `.cursor/rules/*.mdc`. Plain `.md` in that folder is ignored. `AGENTS.md` is always-on markdown without frontmatter.
- Rules can `@`-reference other files instead of inlining them.
- Custom subagents are `.cursor/agents/*.md` with YAML (`name`, `description`, `model`, `readonly`).
- Slash commands still exist as a product surface; new explicit `/` workflows are also modeled as skills with `disable-model-invocation: true`.
