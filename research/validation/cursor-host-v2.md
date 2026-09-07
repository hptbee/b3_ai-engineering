# Cursor host validation v2

**Date:** 2026-09-07  
**Commit inspected:** `675bd41`  
**Host:** Cursor Desktop Agent on Windows (`win32 10.0.26200`)  
**Goal:** Prove whether Cursor actually discovers B3 project skills — not whether descriptions look good on disk.

This is **not** a Codex or Claude Code test.

## Method

1. Record which skills this Agent session was given at start (`available_skills`).
2. Compare that list to official Cursor discovery paths ([Agent Skills](https://cursor.com/docs/skills.md)).
3. Run the intended Cursor adapter mapping (local discovery link).
4. State what this session can and cannot prove after the link exists.

## Official discovery (verified against current docs)

Cursor loads project skills from:

- `.agents/skills/`
- `.cursor/skills/`
- compatibility: `.claude/skills/`, `.codex/skills/`

User-level: `~/.cursor/skills/`, `~/.agents/skills/`.

**Repo-root `skills/` is not a project discovery path.** Nested `SKILL.md` under a discovery root is valid (e.g. `.cursor/skills/engineering/verification/SKILL.md`); identity is the folder that contains `SKILL.md`.

## Baseline (this session, before any adapter link)

| Check | Result | Evidence |
| --- | --- | --- |
| `.cursor/skills/` in repo | Absent | `Get-ChildItem`; `git ls-files` |
| `.agents/skills/` in repo | Absent | same |
| Repo-root `skills/` present | Yes — 23 `SKILL.md` | `git ls-files 'skills/**/SKILL.md'` |
| `AGENTS.md` loaded | Yes | workspace always-on rules |
| B3 skills in host `available_skills` | **No** | Session skill list was Cursor built-ins under `~\.cursor\skills-cursor\` plus user skills under `~\.agents\skills\` (Cloudflare). Zero of: `verification`, `code-review`, `debugging`, `ef-core`, `react-hooks`, etc. |
| Built-in Cursor skills loaded | Yes | `/create-skill`, `/review`, `/canvas`, … |

**Verdict (baseline):** Cursor **did not** present B3 portable skills as Agent Skills. The agent could still *read* `skills/` with filesystem tools because the repo is the workspace. That is **not** skill discovery.

## Adapter mapping attempt

`./adapters/sync-skills.sh cursor` **did not run**: this environment has no `/bin/bash` (`execvpe(/bin/bash) failed`). Outcome of the documented helper: **UNKNOWN / INCOMPLETE**, not PASS.

Windows equivalent used:

```text
cmd /c mklink /J .cursor\skills skills
```

| Check | Result |
| --- | --- |
| Link created | Yes — junction `D:\Project\b3_ai-engineering\.cursor\skills` → `...\skills` |
| `SKILL.md` reachable through the link | **23** |
| PowerShell `New-Item -Target "..\skills"` | Failed — resolved `..\skills` against cwd (`D:\Project\skills`), not against `.cursor\` |
| Unix `ln -s ../skills .cursor/skills` | Not run (no bash) |
| Link committed | **No** — Windows junction is absolute/local; gitignored so it cannot fork a second skill tree |

## What this session still cannot prove

Creating `.cursor/skills` **does not reload** this Agent’s skill list. Cursor discovers skills at session start.

| Capability | Cursor this session |
| --- | --- |
| skill discovery (host metadata) | **FAIL at baseline.** After junction: **NOT VERIFIED** until a **new** Agent chat (or Customize → Skills / `/skill-name`) |
| skill activation (host chooses from descriptions) | **NOT VERIFIED** — this chat was never given B3 skill metadata |
| `/verification` slash invoke | **NOT VERIFIED** — requires UI in a session that has already discovered the link |
| command files as Cursor commands | **NOT VERIFIED** — `commands/*.md` are not `.cursor/commands/` |
| agent files as Cursor subagents | **NOT VERIFIED** — `agents/*.md` are not `.cursor/agents/` |
| Codex / Claude | **NOT VERIFIED** |

## Honest implication

Until a discovery root exists **and** a fresh Agent session lists B3 skills under Customize → Skills or `/`, B3 in Cursor is:

```text
always-on AGENTS.md + rules (if mapped)
     +
manual file reads of skills/
```

not:

```text
description-driven Agent Skills
```

The catalog’s activation design **assumes** the second path. Baseline (this Agent session + User-filtered Skills UI) used the first path.

## Human UI check 1 — User filter (FAIL for project list)

Skills tab with **User: Tùng Huỳnh**: Cloudflare skills from `~\.agents\skills\` only. Expected for that filter. B3 catalog not mixed in.

## Human UI check 2 — Project source (PASS for discovery)

Screenshot: **b3_ai-engineering 23**. Visible skills include `accessibility`, `api-design`, `api-security`, `aspnet-core`, `code-review`, `csharp-async`, `debugging`, `ef-core`, `nodejs-runtime`, `planning`, `problem-solving`, `react-components`, with descriptions matching repo `SKILL.md` frontmatter.

Count **23** matches `git ls-files 'skills/**/SKILL.md'`. Nested layout `.cursor/skills/<category>/<name>/SKILL.md` is discovered. Identity is the folder that contains `SKILL.md` (e.g. `debugging`, not `engineering/debugging`).

**Cursor skill discovery: PASS** for this workspace, after a local `.cursor/skills` → `skills` junction and selecting the project source in Customize → Skills.

### Still NOT VERIFIED

| Capability | Status |
| --- | --- |
| Host auto-activation from description (agent picks the skill without `/`) | NOT VERIFIED — needs a **new** Agent chat with a V-matrix prompt |
| `/verification` (or `/debugging`) explicit invoke | NOT VERIFIED until typed in Agent chat |
| Commands / subagents | NOT VERIFIED (`commands/` and `agents/` are not Cursor discovery roots) |
| Codex / Claude | NOT VERIFIED |
