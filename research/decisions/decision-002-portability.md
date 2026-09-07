# Decision 002 — Portability architecture

## Context

b3 must run on Cursor, Codex, and Claude Code without maintaining three skill corpora.

## Options Considered

1. **Portable core + thin adapters** (current b3 design)
2. **Symlink forest** (`.cursor/skills` → `skills/`) only — no adapter docs
3. **Host-native repos** (separate branches per tool)
4. **Lowest common denominator** — AGENTS.md only, no skills

## Evidence

- Cursor loads `.claude/`, `.codex/`, `.agents/` skill paths (`cursor-agent-skills.md`)
- Codex `.agents/skills` + AGENTS.md chain (`openai-codex-customization.md`)
- Claude CLAUDE.md bridge requirement (`claude-code-skills-plugins.md`, community docs)
- Comparison: `research/comparisons/portability.md`

## Decision

**ADOPT** portable core at repo root + **thin adapters** (mapping/generation later, not content forks).

## Rationale

Evidence shows shared content, divergent loaders — adapters are the correct seam.

## Consequences

- Do not copy skills into `.cursor/skills/` in this repo during synthesis without generator
- Adapter READMEs stay mapping-only until implementation phase
- Hook-based enforcement (optional) lives in adapters, not portable rules

## Confidence

High
