# Portability results v1

Do not infer portability from folder layout alone.

This environment: Cursor cloud agent with B3 on disk. **Codex CLI and Claude Code were not run.** `adapters/sync-skills.sh --dry-run` documents intended paths only.

| Capability | Cursor | Codex | Claude |
| --- | --- | --- | --- |
| skill discovery | **PASS (v2 UI):** Customize → Skills shows **b3_ai-engineering 23** matching repo `SKILL.md` names/descriptions after `.cursor/skills` junction. Baseline this Agent session still had no B3 skills in `available_skills` (started before the link). See `cursor-host-v2.md`. | NOT VERIFIED | NOT VERIFIED |
| skill activation | **NOT VERIFIED** on the host. Description-only re-score is `activation-results-v2.md` (not loader proof). | NOT VERIFIED | NOT VERIFIED |
| command invocation | NOT VERIFIED (no slash/command palette test) | NOT VERIFIED | NOT VERIFIED |
| agent invocation | NOT VERIFIED (no subagent dispatch) | NOT VERIFIED | NOT VERIFIED |
| workflow usage | PARTIAL: files followed manually | NOT VERIFIED | NOT VERIFIED |
| review loop | Manual against markdown; runtime absent | same | same |

`sync-skills.sh --dry-run all` **would** print symlink plans; it does not prove a host loads them.

## Adapter honesty

Adapters are mapping docs + a symlink script. They **ADOPT** decision-002. They do **not** constitute a portability test.

## Decision

**DEFER** real three-host validation. Do not change portable core to add host-specific frontmatter.
