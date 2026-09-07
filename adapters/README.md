# Adapters

Host tools change. The core must not.

```text
Portable Core
     │
     ├── Cursor adapter
     ├── Codex adapter
     └── Claude adapter
```

An adapter maps names, discovery paths, and invocation onto Cursor, Codex, or Claude Code. It does not fork rules, skills, or taxonomy.

**Status:** mapping notes only. No generated host manifests, hooks, or synced copies yet.

## Rules for adapters

- Core files remain the source of truth.
- If a host needs a different filename (`CLAUDE.md`, `.cursor/rules`, and the like), the adapter documents or generates that mapping.
- Do not paste the entire system into each adapter folder.
- If a behavior cannot be expressed portably, extract the portable part first; keep the residue here and mark it host-specific.

## Adapters

| Host | Notes |
| --- | --- |
| [Cursor](cursor/README.md) | Skills, rules, and `AGENTS.md` discovery |
| [Codex](codex/README.md) | `AGENTS.md` and skill discovery |
| [Claude Code](claude/README.md) | `CLAUDE.md`, skills, commands, subagents |

Add a new host as another thin folder. Do not add a fourth copy of `rules/`.
