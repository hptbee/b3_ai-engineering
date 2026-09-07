# OpenAI Codex Customization (AGENTS.md, skills, subagents)

## Source

- https://developers.openai.com/codex/guides/agents-md
- https://developers.openai.com/codex/concepts/customization
- https://github.com/openai/codex (`codex-rs/core/src/project_doc.rs`, `agents_md.rs`)

## Tier

Tier 1

## Purpose

How Codex loads persistent instructions, skills, memories, MCP, and subagents.

## Architecture

**AGENTS.md chain:** global (`~/.codex/AGENTS.md` or override) → walk from git root to CWD, one file per directory (`AGENTS.override.md` wins locally). Concatenate with separators; **32 KiB default cap** (`project_doc_max_bytes`). Closer directories override earlier text by appearing later.

**Skills:** repo `.agents/skills/`; global `$HOME/.agents/skills/`. Metadata visible; full skill loaded on use.

**Subagents:** documented as customization layer (delegation) — implementation host-specific.

## Important Patterns

- Nested AGENTS.md for monorepo team overrides
- Feedback loop: correct agent → update AGENTS.md
- Keep AGENTS.md small; skills for repeatable workflows
- Fallback filenames via `project_doc_fallback_filenames` in config.toml

## Skill Design

Aligns with Agent Skills standard; repo path `.agents/skills/` (note `.agents/` prefix vs `.claude/`).

## Rules / Instructions

AGENTS.md = durable project guidance, not encyclopedic docs. Global vs repo split: personal style global, team rules in repo.

## Agents

Subagents listed alongside skills/MCP as customization primitives.

## Commands / Workflows

`/init` scaffolds AGENTS.md. `/skills` browses skills.

## Evaluation

No first-party trigger eval docs in Codex guides (contrast anthropics skill-creator).

## Portability

AGENTS.md content portable. Discovery order, byte limits, override filenames — Codex adapter documentation.

## Strengths

- Explicit merge semantics in open-source Rust (`LoadedAgentsMd`, provenance markers)
- Clear global vs repo split
- `.agents/skills` parallels other tools' `.agents/skills` path (Cursor also reads this)

## Weaknesses / Trade-offs

- 32 KiB cap forces splitting across nested dirs or external skills
- Concatenation can hide conflicts silently
- Skills docs pointer-only in repo (`docs/skills.md` → developers.openai.com)

## Interesting Implementation Details

- `discover_project_doc_paths` walks from project root markers to CWD
- Separator inserted on transition from user/internal instructions to project docs

## Relevant Files

- `openai/codex/codex-rs/core/src/project_doc.rs`
- `openai/codex/codex-rs/core/src/agents_md.rs`

## Evidence

- OpenAI developers docs (fetched 2026-09-07)
- GitHub source headers in `project_doc.rs`, `agents_md.rs`

## Relevance to b3-ai-engineering

Validates AGENTS.md + `.agents/skills/` as Codex adapter targets; portable core should not assume Codex byte limits — document in adapter.

## Initial Recommendation

ADAPT
