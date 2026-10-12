# Codex adapter

**Status:** implemented adapter; runtime skill discovery is UNKNOWN / INCOMPLETE in the current checkout. Root AGENTS.md is committed; skills are intended to be installed locally at .agents/skills as a link to the canonical Cursor skill tree. Runtime evidence is recorded in research/validation/codex-host-v1.md.

## This repo → Codex

| Core | Codex mapping |
| --- | --- |
| `AGENTS.md` | Primary operating file; merged chain subject to ~32 KiB default cap |
| `rules/*.md` | Include or link from `AGENTS.md` — do not duplicate prose |
| `.cursor/skills/` | Canonical source; expose through `.agents/skills` via [`../sync-skills.sh`](../sync-skills.sh) or [`../sync-skills.ps1`](../sync-skills.ps1) |
| `.cursor/commands/` | Prompt routing: name the intent and point to the command file; no duplicate Codex command files |
| `.cursor/agents/` | Role prompt source for delegated reviewer/fixer/security/architecture work; file-based Codex custom-agent discovery is not established |

Review-loop model slots stay host-configured (`review-loop/models.md`). Do not hard-code vendor model names in skill bodies.

Codex discovers `.agents/skills/` at repo root. Same layout as agentskills.io. On Windows use `./adapters/sync-skills.ps1 -HostName codex`; on macOS/Linux use `./adapters/sync-skills.sh codex`.

## Capability classification

| Codex mechanism | B3 use | Classification |
| --- | --- | --- |
| Root `AGENTS.md` and nested instruction chain | Durable project map and precedence | SUPPORTED |
| `.agents/skills` + `SKILL.md` metadata | Existing B3 skills, explicit and description-driven selection | SUPPORTED |
| Prompt routing / explicit skill invocation | Cursor command intent (`plan`, `implement`, `debug`, `review`, `verify`, `review-loop`, `autodev`) | SUPPORTED |
| Delegated multi-agent roles | Review-loop reviewer/fixer separation | SUPPORTED BY CODEX; B3 role isolation UNKNOWN / INCOMPLETE |
| `.codex/config.toml` | No repository defaults required | SUPPORTED BUT UNNECESSARY FOR B3 |
| Repository `.codex/agents` custom-agent files | Cursor role-file parity | EXPERIMENTAL / UNCERTAIN; not created |
| Hooks, MCP, plugins | Not needed to preserve B3 meaning | SUPPORTED BUT UNNECESSARY FOR B3 |
| Host model/reasoning defaults | Keep inherited/user-local | SUPPORTED BUT UNNECESSARY FOR B3 |

## Command and role routing

Use the existing command file as the procedure selector: “plan this change”, “implement this change”, “debug this failure”, “review this diff”, “verify this claim”, “run the review loop”, or “run autonomous development” (`autodev`, `resume`, `status`). The selected procedure loads the reusable skill or `workflows/autonomous-development.md`; it does not create a second skill copy.

`autodev` is prompt routing to `.cursor/commands/autodev.md`. Codex does not gain a native slash command or a separate procedure. Checkpoints stay in the repo under change at `.b3/autodev/`. A stopped Codex session does not resume until the user invokes the intent again.

For review-loop delegation, send the existing `.cursor/agents/reviewer.md`, `fixer.md`, `security-reviewer.md`, or `architecture-reviewer.md` role text to an isolated delegated agent when available. Reviewer prompts must prohibit edits; fixer prompts may make only confirmed minimal fixes. The parent remains the orchestrator and owns `PASS`, `FAIL`, and `UNKNOWN / INCOMPLETE`.

## AGENTS.md merge chain

Keep root `AGENTS.md` concise; defer procedures to skills.

If byte cap truncates context:
1. Shorten `AGENTS.md` to pointers
2. Rely on skill descriptions for activation
3. Split rarely-used docs to `docs/` + skill references

## Symlink

```bash
./adapters/sync-skills.sh codex
# creates .agents/skills → ../.cursor/skills
```

Do **not** run `all` while using Cursor in this repo if that would also create `.claude/skills` — Cursor cross-loads compatibility dirs.

## Thin by design

CLI flags and Codex-only config stay here. Core rules and skill procedures remain host-agnostic.

## References

- [`../README.md`](../README.md)
- `research/sources/openai-codex-customization.md`
- `research/sources/agentskills-open-standard.md`
