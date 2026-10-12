# Codex host validation v1

**Date:** 2026-09-11  
**Platform:** Windows, PowerShell, repository `D:\Project\b3_ai-engineering`  
**Codex surface:** Codex CLI 0.153.4; this desktop session also loaded root `AGENTS.md`.  
**HEAD:** `9edc223` (`main`)

This is runtime evidence for the adapter, not a claim that every Codex product surface is identical across releases.

## Architecture tested

`.cursor/skills/` remains the canonical committed skill source. The ignored local installation `.agents/skills` is a Windows junction to that directory. `AGENTS.md` provides durable cross-host routing. Cursor commands and agent files remain unchanged; Codex selects those procedures and roles through prompts/delegation.

## Evidence

| Surface / scenario | Expected | Observed | Result |
| --- | --- | --- | --- |
| Root `AGENTS.md` loading | Codex receives B3 map and constraints | This Codex session received the repository `AGENTS.md` instructions before task work | PASS |
| Local skill discovery path | .agents/skills resolves to canonical tree | Current Codex probe found an ordinary empty .agents/skills directory: no junction target and no discoverable SKILL.md files | FAIL |
| Explicit invocation | A named B3 skill loads its method | Codex could read source under .cursor/skills, but could not discover it through .agents/skills; explicit repository-skill activation was not proven | UNKNOWN / INCOMPLETE |
| Description-driven activation | A matching task selects a relevant B3 skill | Not independently observed in a fresh child session | UNKNOWN / INCOMPLETE |
| Custom agent discovery | Repository agent files are discovered natively | Codex CLI exposes delegation/session commands but no documented `.codex/agents` repository surface; no such files were created | UNKNOWN / INCOMPLETE |
| Read-only reviewer behavior | Reviewer can inspect without edits | B3 reviewer role is `readonly: true` in Cursor; Codex delegated-role runtime not independently exercised | UNKNOWN / INCOMPLETE |
| Fixer role behavior | Fixer makes minimal confirmed fix and verifies | Role contract is preserved in `.cursor/agents/fixer.md`; Codex delegation not independently exercised | UNKNOWN / INCOMPLETE |
| Review-loop orchestration | Parent preserves lifecycle and termination semantics | `review-loop/spec.md` and `strategy.md` are routed by `AGENTS.md`; no fresh delegated Codex loop run was completed | UNKNOWN / INCOMPLETE |
| Verification semantics | Missing evidence remains UNKNOWN / INCOMPLETE | This record reports missing link/discovery as FAIL or UNKNOWN / INCOMPLETE rather than PASS | PASS |
| Cursor regression | Existing Cursor paths remain committed and intact | `.cursor/skills`, `.cursor/commands`, `.cursor/agents`, `.cursor/rules` unchanged by adapter setup | PASS |

## Capability decisions

Supported: root/nested `AGENTS.md` guidance, `.agents/skills`, explicit and implicit skill routing, sandbox modes, model/reasoning configuration, MCP/plugins, and delegated multi-agent orchestration.

Supported but unnecessary for B3: repository `.codex/config.toml`, hooks, MCP server code, plugin packaging, and hard-coded model selection.

Experimental / uncertain: a repository-native `.codex/agents` custom-agent file surface and full delegated review-loop isolation in this installed CLI context.

Not applicable: Cursor slash-command files as Codex-native commands; they remain prompt-routing selectors.

## Known limitations and manual follow-up

Fresh Codex interactive sessions should be run from this checkout after setup to test one explicit skill, one description-driven skill, and a delegated reviewer/fixer pair. The current non-interactive evidence is intentionally incomplete for those runtime behaviors. Do not label the adapter fully verified until those scenarios produce observable tool/session evidence.
