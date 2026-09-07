# Portability results v1

Do not infer portability from folder layout alone.

This environment: Cursor cloud agent with B3 on disk. **Codex CLI and Claude Code were not run.** `adapters/sync-skills.sh --dry-run` documents intended paths only.

| Capability | Cursor | Codex | Claude |
| --- | --- | --- | --- |
| skill discovery | NOT VERIFIED (no `.cursor/skills` symlink committed; this run used repo-root `skills/` via AGENTS.md, not host loader) | NOT VERIFIED | NOT VERIFIED |
| skill activation | PARTIAL: this agent read `SKILL.md` descriptions because the task loaded the repo — **not** proof of Cursor metadata triggering | NOT VERIFIED | NOT VERIFIED |
| command invocation | NOT VERIFIED (no slash/command palette test) | NOT VERIFIED | NOT VERIFIED |
| agent invocation | NOT VERIFIED (no subagent dispatch) | NOT VERIFIED | NOT VERIFIED |
| workflow usage | PARTIAL: files followed manually | NOT VERIFIED | NOT VERIFIED |
| review loop | Manual against markdown; runtime absent | same | same |

`sync-skills.sh --dry-run all` **would** print symlink plans; it does not prove a host loads them.

## Adapter honesty

Adapters are mapping docs + a symlink script. They **ADOPT** decision-002. They do **not** constitute a portability test.

## Decision

**DEFER** real three-host validation. Do not change portable core to add host-specific frontmatter.
