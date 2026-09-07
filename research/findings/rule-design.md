# Rule design

## Observation

Hosts split **always-on constraints** (rules / AGENTS.md) from **on-demand methods** (skills). Cursor adds activation modes: always, intelligent, glob, manual.

## Evidence

- Cursor rules doc: Team → Project → User precedence; `.mdc` frontmatter matrix
- AGENTS.md open format: closest file wins; user chat overrides
- Codex: nested AGENTS.md chain with byte cap — forces brevity
- Migration guides: dynamic rules → skills; always-apply stays rules

## Pattern

| Layer | Load | Content |
| --- | --- | --- |
| Hard constraints | Always or strong default | Short, testable |
| Project facts | AGENTS.md (always) | Build/test commands, architecture pointers |
| Procedures | Skills | Workflows, checklists |
| Taste | Profile / personal knowledge | Not rules |

## Why it matters

Mis-layering causes token waste (procedures always-on) or weak enforcement (constraints buried in skills).

## Trade-offs

Multiple parallel systems (AGENTS.md + rules + skills + CLAUDE.md) confuse authors without explicit taxonomy — b3 addresses this in docs

## Potential application

b3 foundation rules stay minimal + YAML metadata. Do not migrate procedures into `rules/` during synthesis.

## Confidence

High
