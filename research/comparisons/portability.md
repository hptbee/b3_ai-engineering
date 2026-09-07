# Portability comparison

## What can be standardized? (evidence: yes)

| Artifact | Evidence |
| --- | --- |
| `SKILL.md` + agentskills frontmatter | Spec + Cursor + Claude + Codex + MS Agent Framework |
| `AGENTS.md` markdown content | agents.md + Codex + Cursor nested support |
| Portable `rules/*.md` constraints | Conceptual; map to `.mdc`/hooks in adapters |
| Workflow/review **method** docs | SWE-Review, Anthropic patterns, b3 docs |
| Eval **concepts** (should/not/near-miss) | agentskills.io + dreaming.press |
| Directory convention `skills/<name>/` at repo root | Supported by `.agents/skills` alias loading |

## What cannot be standardized? (evidence: host-specific)

| Mechanism | Hosts | Notes |
| --- | --- | --- |
| Discovery paths | Cursor: `.cursor/`, `.agents/`; Claude: `.claude/`; Codex: `.agents/` + home | Single symlink tree insufficient for all features |
| Hooks / stop gates | Claude Code plugins, dev-loop | No Codex equivalent in portable markdown |
| Rule activation `.mdc` | Cursor | Not AGENTS.md |
| CLAUDE.md native load | Claude | Requires `@AGENTS.md` bridge |
| AGENTS.md merge/byte cap | Codex | 32 KiB default, override chain |
| Plugin marketplace namespacing | Claude/Cursor | `/plugin:skill` |
| Team rules dashboard | Cursor Team | Not in repo |
| MCP/hook JSON | Claude plugins | Adapter-only |

## Recommended architecture (evidence-backed)

```text
Portable Core (single source)
  AGENTS.md, rules/, skills/, docs/, research/
           +
Thin Adapters
  path mapping, CLAUDE.md bridge, optional hook wrappers, generated stubs
```

**Verdict:** Portable core + thin adapters is **supported by evidence**, not merely aesthetic — multiple vendors converged on same SKILL.md/AGENTS.md content with different loaders.

## Risks

- Authors duplicate skills into each host folder (anti-pattern)
- Adapter drift if generated files committed without single source
- Hook-based enforcement tempts leaving portable core for Claude-only users

## b3 alignment

Current b3 structure matches evidence. Adapters remain docs-only — appropriate until synthesis phase implements generators.
