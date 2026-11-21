# b3-ai-engineering

A personal AI-assisted software engineering system built on a **host-neutral canonical core** supporting **Cursor**, **Codex**, **Claude Code**, and **Antigravity**. The conceptual core (Agent Skills, rules, commands, agents, workflows, review-loop, evals, research) stays portable; thin host wrappers and adapters map it onto each product without duplicating prose.

This is an **evolving** operating layer for AI coding agents. It is not a company handbook.

## Repository layout

```text
b3-ai-engineering/
├── AGENTS.md                 Universal always-on map (Cursor, Codex, Antigravity)
├── CLAUDE.md                 Thin @AGENTS.md bridge (Claude Code)
├── README.md                 Human-facing entry
├── rules/                    Portable rule bodies (source of meaning)
├── skills/                   Canonical skills (Agent Skills SKILL.md)
├── commands/                 Canonical user-facing / actions
├── agents/                   Canonical reviewer / fixer subagent specs
├── workflows/                Default product sequence & /autodev lifecycle
├── review-loop/              Spec + orchestration procedure
├── knowledge/                Reusable internal knowledge
├── research/                 Provenance & architecture decisions
├── evals/                    Fixtures (not a runner)
├── adapters/                 4-host adapters, command-skills & installers
├── .cursor/rules/            Committed thin Cursor .mdc wrappers (@rules/*.md)
├── .agents/skills.json       Committed Antigravity 1-level skill manifest
├── scripts/                  Repository tooling & validation
└── docs/                     Architecture, standards, contracts
```

Catalogs: [`skills/README.md`](skills/README.md), [`docs/architecture.md`](docs/architecture.md). Universal map: [`AGENTS.md`](AGENTS.md).

## Why it exists

Agents are useful when they have durable constraints, reusable methods, verification instead of assertion, a way to learn without turning preference into dogma, and a core whose **meaning** is not rewritten per product.

## Host-neutral core, 4-host activation

Skills are Agent Skills (`SKILL.md`) stored canonically under `skills/`, commands under `commands/`, subagent roles under `agents/`, and rule bodies under `rules/`. Each host consumes that single source of truth through thin committed entrypoints (`.cursor/rules/*.mdc`, `CLAUDE.md`, `.agents/skills.json`) and/or gitignored local links managed by `adapters/sync-skills.{ps1,sh}` and `adapters/install-product.{ps1,sh}`.

Evidence over opinion. Progressive disclosure. Small composable skills. Research, then adapt — do not copy skill packs.

## Installation

Host-specific notes: [`adapters/cursor/README.md`](adapters/cursor/README.md), [`adapters/codex/README.md`](adapters/codex/README.md), [`adapters/claude/README.md`](adapters/claude/README.md), [`adapters/antigravity/README.md`](adapters/antigravity/README.md).

> **Coexistence note:** Do not activate conflicting skill discovery roots in the same checkout. Cursor cross-loads `.agents/skills` and `.claude/skills`, and Antigravity reads both `.agents/skills.json` and `.agents/skills`. `sync-skills` guards against conflicts unless `-Force` / `--force` is passed.

### Cursor

**Work inside this B3 repository:** `.cursor/rules/*.mdc` and `AGENTS.md` work on fresh clone. To expose `skills/`, `commands/`, and `agents/` on Cursor's native paths (gitignored links):

```powershell
# Windows
.\adapters\sync-skills.ps1 -HostName cursor
.\adapters\sync-skills.ps1 -HostName cursor -VerifyOnly
```

```bash
# macOS / Linux
./adapters/sync-skills.sh cursor
./adapters/sync-skills.sh --verify cursor
```

**Work in a separate product repository:**

```powershell
# Windows
.\adapters\install-product.ps1 -ProductRoot D:\path\to\your-product -HostName cursor
```

```bash
# macOS / Linux
./adapters/install-product.sh --product-root /path/to/your-product --host cursor
```

The installer writes `{product}/.b3/home`, `{product}/AGENTS.md` (when missing), `{product}/.cursor/commands/*.md` (including `autodev.md`), and `.b3/autodev/` in `.gitignore`. It does **not** copy `skills/` into the product. Optional user-level link (once per machine):

```powershell
# Windows — replace the target with your B3 clone
$skills = 'D:\Project\b3_ai-engineering\skills'
$dest = Join-Path $env:USERPROFILE '.cursor\skills\b3-ai-engineering'
New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
if (-not (Test-Path -LiteralPath $dest)) { cmd /c mklink /J "$dest" "$skills" }
```

```bash
# macOS / Linux
ln -sfn /path/to/b3_ai-engineering/skills ~/.cursor/skills/b3-ai-engineering
```

### Codex

**Inside this B3 checkout:** Create the local flattened `.agents/skills/<name>` index (core `skills/` + `adapters/command-skills/`):

```powershell
.\adapters\sync-skills.ps1 -HostName codex
.\adapters\sync-skills.ps1 -HostName codex -VerifyOnly
```

```bash
./adapters/sync-skills.sh codex
./adapters/sync-skills.sh --verify codex
```

**Separate product repo:** Use `install-product` with `-HostName codex` / `--host codex`. That writes `.b3/home`, a thin `AGENTS.md` if missing, and a gitignored flattened `.agents/skills/<name>` index so Codex can invoke `$autodev` (and `$plan`, `$implement`, …).

### Claude Code

**Inside this B3 checkout:** Root `CLAUDE.md` (`@AGENTS.md`) is committed and works on fresh clone. Create the local gitignored `.claude/skills/<name>` (core `skills/` + `adapters/command-skills/`, unified slash commands as skills) and `.claude/agents` links:

```powershell
.\adapters\sync-skills.ps1 -HostName claude
.\adapters\sync-skills.ps1 -HostName claude -VerifyOnly
```

```bash
./adapters/sync-skills.sh claude
./adapters/sync-skills.sh --verify claude
```

**Separate product repo:** Use `install-product` with `-HostName claude` / `--host claude`. That writes `.b3/home`, `AGENTS.md` and `CLAUDE.md` (when missing), plus gitignored flattened `.claude/skills/<name>` and `.claude/agents` links.

### Antigravity

- **Inside this B3 checkout:** Root `AGENTS.md` and committed `.agents/skills.json` (1-level category entries over `skills/*` plus `adapters/command-skills`) work out of the box without creating a `.agents/skills` link. Verify with:

```powershell
.\adapters\sync-skills.ps1 -HostName antigravity -VerifyOnly
```

```bash
./adapters/sync-skills.sh --verify antigravity
```

- **Separate product repo:** Run `install-product` with `-HostName antigravity` / `--host antigravity` (or use `-HostName cursor` + the global plugin below if Cursor also opens that repo):

```powershell
.\adapters\install-product.ps1 -ProductRoot D:\path\to\your-product -HostName antigravity
```

```bash
./adapters/install-product.sh --product-root /path/to/your-product --host antigravity
```

- **Machine-global plugin:** Generate `~/.gemini/config/plugins/b3-ai-engineering/` (rules, 1-level skill links, and isolated `agents/*.md` subagents) via:

```powershell
.\adapters\antigravity\install-plugin.ps1
```

```bash
./adapters/antigravity/install-plugin.sh
```

More detail: [`adapters/README.md`](adapters/README.md), [`research/decisions/decision-011-product-repo-attach.md`](research/decisions/decision-011-product-repo-attach.md), [`research/decisions/decision-013-host-neutral-multi-host-layout.md`](research/decisions/decision-013-host-neutral-multi-host-layout.md).

## Architecture

Definitions: [`docs/architecture.md`](docs/architecture.md). Operating notes: [`AGENTS.md`](AGENTS.md). Conflicts: [`docs/precedence.md`](docs/precedence.md).

```text
Rules constrain → Skills provide methods → Commands start work
 → Agents isolate roles → Verification / review-loop check
 → Lessons → Knowledge
```

**Profiles** add personal context and are not created yet (`knowledge/personal/` holds background). **Adapters** map the canonical core onto Cursor, Codex, Claude Code, and Antigravity; they must not fork meaning.

## Research → knowledge → skills

```text
External sources → research/ → knowledge/ → skills / rules / workflows
```

`research/` is intake plus `validation/` evidence. `knowledge/` is what the system knows. Skill `references/` are task aids. Method: [`docs/research-methodology.md`](docs/research-methodology.md). Evolution: [`docs/system-lifecycle.md`](docs/system-lifecycle.md). Lessons do **not** automatically become rules.

## Review loop

Specified in [`review-loop/spec.md`](review-loop/spec.md). Orchestration: [`review-loop/strategy.md`](review-loop/strategy.md) (compact subagent handoffs, active-only findings slices, and `scripts/autodev-guard.{ps1,sh} diff-scope` noise filtering). Invoke: [`commands/review-loop.md`](commands/review-loop.md). Host model slots: `review-loop/models.md`.

## Autonomous development

One invocation runs pre-flight baseline checks, planning, JIT task analysis, implementation, risk-tiered review, focused commits, and Git-verified resume. Procedure: [`workflows/autonomous-development.md`](workflows/autonomous-development.md) (templates and resume reconciliation under `workflows/references/`). Guard helpers: [`scripts/README.md`](scripts/README.md). Command: [`commands/autodev.md`](commands/autodev.md) (and `adapters/command-skills/autodev/SKILL.md` for skill-based hosts). Checkpoints live in the repo under change at `.b3/autodev/` (gitignored). Product-repo setup: [Installation](#installation). A stopped session does not resume until the user invokes the workflow again.

## Context budget & validation

Static always-on and workflow token budgets are tracked by [`scripts/measure-context.ps1`](scripts/measure-context.ps1) / [`scripts/measure-context.sh`](scripts/measure-context.sh) (`-Strict` / `--strict`). Behavioral, smoke, and eval schema checks are cataloged in [`scripts/README.md`](scripts/README.md).

## Evaluation

Activation fixtures live under `evals/`. Automated runner deferred. Layout: [`docs/evaluation.md`](docs/evaluation.md).

## Personal profile

Background: [`knowledge/personal/engineering-context.md`](knowledge/personal/engineering-context.md). A `profiles/` directory is **not created** until Tùng records it.

```text
Personal preference  ≠  Engineering rule
```

## Platforms

```text
Canonical core (rules/, skills/, commands/, agents/)
  → .cursor/rules/*.mdc + sync-skills cursor     → Cursor
  → AGENTS.md + sync-skills codex                → Codex
  → CLAUDE.md + sync-skills claude               → Claude Code
  → AGENTS.md + .agents/skills.json / plugin     → Antigravity
```

## Current maturity

| Area | Status |
| --- | --- |
| Architecture, standards, precedence, lifecycle | Present |
| Foundation rules + Cursor `.mdc` activation + Claude `CLAUDE.md` bridge | Present |
| Engineering + domain skills | Present (see [`skills/README.md`](skills/README.md)) |
| Commands, agents | Present (host-neutral canonical core) |
| Eval fixtures | Present; runner deferred |
| Review-loop orchestration | Present (agent procedure; host isolation **UNKNOWN / INCOMPLETE**) |
| Autonomous development | Present as workflow + `commands/autodev.md` + `adapters/command-skills/autodev/` |
| Knowledge after lessons | Minimal (`knowledge/personal/` only) |
| Profile files | Not created (`knowledge/personal/` holds background) |
| Cursor / Codex / Claude / Antigravity adapters | Present (`sync-skills`, `install-product`, Antigravity plugin); live runtime host discovery **UNKNOWN / INCOMPLETE** |

**Present rules:** `engineering-principles`, `verification`, `portability`, `evidence-and-provenance`, `simplest-correct`.
