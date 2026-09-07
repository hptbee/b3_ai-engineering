# Context engineering

## Observation

Context is engineered by **what loads when**: always-on files (AGENTS.md, always-apply rules) vs metadata-only catalogs (skill descriptions) vs isolated subagent windows.

## Evidence

- AGENTS.md / CLAUDE.md split and bridging (`@AGENTS.md`, symlinks)
- Codex 32 KiB AGENTS.md cap → nested files
- Cursor Team → Project → User merge order
- Cursor built-in subagents created from analysis of context-limit failures
- skills.sh/VoltAgent path table: per-host discovery roots

## Pattern

1. Keep always-on surface minimal (AGENTS.md + hard rules only)
2. Publish skill metadata catalog at startup
3. Scope file-specific guidance via globs/paths/nested AGENTS.md
4. Offload verbose work to subagents

## Why it matters

False confidence often comes from **missing context**, not wrong reasoning — review loops fail when implementer and reviewer share overloaded context.

## Trade-offs

Too little always-on context → agent rediscovers project facts each session

## Potential application

b3 AGENTS.md stays router to docs/skills/rules. Personal profile is low precedence context, not always-on dump.

## Confidence

High
