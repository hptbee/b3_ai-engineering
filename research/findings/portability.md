# Portability

## Observation

**Portable core** is real for: Markdown, AGENTS.md content, SKILL.md (+ standard frontmatter), workflow/review **concepts**. **Not portable**: hooks, plugin manifests, discovery paths, rule `.mdc` activation, byte limits, marketplace namespacing.

## Evidence

- agentskills.io adopted by Cursor, Claude, Codex, Copilot (VoltAgent table)
- Cursor loads `.claude/skills`, `.codex/skills`, `.agents/skills`
- Claude requires CLAUDE.md bridge for AGENTS.md
- Codex-specific merge/separator logic in Rust source
- Each review-loop repo tightly coupled to Claude/Codex hooks

## Pattern

```text
Portable Core (repo root)
  skills/, rules/, docs/, AGENTS.md, research/
        +
Thin Adapters (adapters/cursor|codex|claude/)
  paths, bridges, hooks, generated host files
```

## Why it matters

b3-ai-engineering explicit goal — evidence supports architecture choice, not just preference.

## Trade-offs

Lowest-common-denominator core cannot use host strengths (hooks, stop gates) without adapter-specific optional layers

## Potential application

Keep `adapters/` mapping-only until synthesis phase implements generators. Never fork skill text per host.

## Confidence

High
