# Cursor adapter

**Status:** path matrix + sync script documented. No `.cursor/` tree committed yet.

## Portable core → Cursor

| Core | Cursor mapping |
| --- | --- |
| `AGENTS.md` | Read as-is (including nested monorepo roots) |
| `rules/*.md` | Map to `.cursor/rules/*.mdc` or user rules — same meaning, add activation metadata in adapter layer |
| `skills/<name>/SKILL.md` | Symlink `skills/` → `.cursor/skills/` via [`../sync-skills.sh`](../sync-skills.sh) |
| `commands/` | Cursor commands or skills with `disable-model-invocation: true` when command layer exists |
| `agents/` | `.cursor/agents/` when roles exist |

Cursor also loads `.agents/skills/`, `.claude/skills/`, and `.codex/skills/` for cross-tool repos — prefer **one** symlinked tree to avoid drift.

## Discovery paths (priority order)

1. `.cursor/skills/` — Cursor-native
2. `.agents/skills/` — shared alias (Codex-compatible)
3. `.claude/skills/`, `.codex/skills/` — cross-loader

**Recommendation:** symlink portable `skills/` to `.cursor/skills/` only; let Cursor cross-load if configured, or add `.agents/skills` symlink for Codex parity.

## Cursor-specific frontmatter (optional overlays)

Generate small overlay stubs if needed — do not edit portable SKILL.md:

```yaml
# .cursor/skills/<name>/SKILL.md overlay — example only
paths: "src/frontend/**"   # scope to subtree
disable-model-invocation: false
```

Nested `.cursor/skills/` under package folders auto-scopes like `paths`.

## Subagents vs skills

| Use subagent when | Use skill when |
| --- | --- |
| Isolated context, parallel exploration | Repeatable procedure, on-demand method |
| Long autonomous search | Single-purpose engineering workflow |

Map portable `agents/` roles to `.cursor/agents/` when implemented. Namespaced subagent types are host-specific — see Claude adapter for Trail of Bits-style names.

## Built-in Cursor skills

Product ships `/create-skill`, `/migrate-to-skills`, `/review`, subagent creators — separate from this repo's portable skills.

## Thin by design

Cursor UI, MCP wiring, team marketplace, and hooks stay here. Verification, review method, and engineering skills stay in portable core.

## References

- [`../README.md`](../README.md) — full matrix
- `research/sources/cursor-agent-skills.md`
- `research/sources/cursor-subagents.md`
