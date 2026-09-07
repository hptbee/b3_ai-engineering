# Skill design

## Observation

Strong systems converge on **one folder = one capability** with `SKILL.md` as the sole required file, optional `scripts/`, `references/`, `assets/`.

## Evidence

- agentskills.io specification (`research/sources/agentskills-open-standard.md`)
- Cursor, Claude Code, Codex docs (`cursor-agent-skills.md`, `claude-code-skills-plugins.md`, `openai-codex-customization.md`)
- Reference corpuses: `anthropics/skills.md`, `obra-superpowers.md` (many small skills)

## Pattern

```text
skill-name/
├── SKILL.md          # required: frontmatter + procedure
├── scripts/          # deterministic execution
├── references/       # on-demand depth
└── assets/           # templates, static inputs
```

## Why it matters

Folder packaging enables version control, progressive loading, and cross-host discovery without duplicating prose in always-on context.

## Trade-offs

- Many small skills increase catalog management and trigger-eval burden
- Large domain skills (e.g. document processing in anthropics/skills) need heavy references — still one skill, not many rules

## Potential application

b3-ai-engineering already matches this in `docs/skill-standard.md`. Keep one concern per skill; defer domain packs to research synthesis phase.

## Confidence

High
