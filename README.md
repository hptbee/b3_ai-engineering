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
├── workflows/                Default product sequence & /b3-ship lifecycle
├── review-loop/              Spec + orchestration procedure
├── knowledge/                Reusable internal knowledge
├── research/                 Provenance & architecture decisions
├── evals/                    Fixtures (not a runner)
├── adapters/                 4-host adapters, command-skills & installers
├── .cursor/rules/            Committed thin Cursor .mdc wrappers (@rules/*.md)
├── .agents/skills.json       Committed Antigravity 1-level skill manifest
├── scripts/                  Repository tooling & validation
├── config/                   Optional Markdown model preference example (models.example.md)
└── docs/                     Architecture, standards, contracts
```

Catalogs: [`skills/README.md`](skills/README.md), [`docs/architecture.md`](docs/architecture.md), [`docs/model-preferences.md`](docs/model-preferences.md). Universal map: [`AGENTS.md`](AGENTS.md).

## Why it exists

Agents are useful when they have durable constraints, reusable methods, verification instead of assertion, a way to learn without turning preference into dogma, and a core whose **meaning** is not rewritten per product.

## Host-neutral core, 4-host activation

Skills are Agent Skills (`SKILL.md`) stored canonically under `skills/`, commands under `commands/`, subagent roles under `agents/`, and rule bodies under `rules/`. Each host consumes that single source of truth through thin committed entrypoints (`.cursor/rules/*.mdc`, `CLAUDE.md`, `.agents/skills.json`) and/or gitignored local links managed by `adapters/sync-skills.{ps1,sh}` and `adapters/install-product.{ps1,sh}`.

Evidence over opinion. Progressive disclosure. Small composable skills. Research, then adapt — do not copy skill packs.

## Installation

Host-specific notes: [`adapters/cursor/README.md`](adapters/cursor/README.md), [`adapters/codex/README.md`](adapters/codex/README.md), [`adapters/claude/README.md`](adapters/claude/README.md), [`adapters/antigravity/README.md`](adapters/antigravity/README.md).

> **Coexistence note:** Do not activate conflicting skill discovery roots in the same checkout. Cursor cross-loads `.agents/skills` and `.claude/skills`, and Antigravity reads both `.agents/skills.json` and `.agents/skills`. `sync-skills` guards against conflicts unless `-Force` / `--force` is passed.

### Global machine-wide install (Cursor & Antigravity)

Install once across all local repositories without copying `skills/` or modifying individual repos (`cursor`, `antigravity`, or `all`; supports `install`, `verify`, `update`, `uninstall`, `-DryRun`/`--dry-run`, `-Force`/`--force`):

```powershell
# Windows PowerShell
.\adapters\install-global.ps1 -HostName cursor
.\adapters\install-global.ps1 -HostName antigravity
.\adapters\install-global.ps1 -HostName all
.\adapters\install-global.ps1 verify -HostName all
```

```bash
# macOS / Linux / Git Bash
./adapters/install-global.sh --host cursor
./adapters/install-global.sh --host antigravity
./adapters/install-global.sh --host all
./adapters/install-global.sh verify --host all
```

Details, project overrides, and manual host runtime smoke checklists: [`adapters/cursor/README.md`](adapters/cursor/README.md), [`adapters/antigravity/README.md`](adapters/antigravity/README.md).

### Cursor

**Global one-time install:** makes all 7 commands, flattened 1-level skills, 5 subagents, global `b3-home`, and a compact `b3-user-rules.txt` User Rules template available under `~/.cursor/` (or via `.\adapters\install-global.ps1 -HostName cursor`):

```powershell
# Windows
.\adapters\cursor\install-global.ps1
.\adapters\cursor\install-global.ps1 verify
```

```bash
# macOS / Linux / Git Bash
./adapters/cursor/install-global.sh
./adapters/cursor/install-global.sh verify
```

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

**Optional per-project attach (`install-product`):** for shared repo-committed `.b3/home` + `.cursor/commands/*.md` (without copying `skills/`):

```powershell
# Windows
.\adapters\install-product.ps1 -ProductRoot D:\path\to\your-product -HostName cursor
```

```bash
# macOS / Linux
./adapters/install-product.sh --product-root /path/to/your-product --host cursor
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

**Separate product repo:** Use `install-product` with `-HostName codex` / `--host codex`. That writes `.b3/home`, a thin `AGENTS.md` if missing, and a gitignored flattened `.agents/skills/<name>` index so Codex can invoke `$b3-ship` (and `$b3-plan`, `$b3-implement`, …).

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

- **Machine-global plugin:** Manage `~/.gemini/config/plugins/b3-ai-engineering/` (rules, 1-level skill links, command skills, and isolated `agents/*.md` subagents; or use `.\adapters\install-global.ps1 -HostName antigravity`) via:

```powershell
.\adapters\antigravity\install-plugin.ps1
.\adapters\antigravity\install-plugin.ps1 verify
```

```bash
./adapters/antigravity/install-plugin.sh
./adapters/antigravity/install-plugin.sh verify
```

More detail: [`adapters/README.md`](adapters/README.md), [`research/decisions/decision-011-product-repo-attach.md`](research/decisions/decision-011-product-repo-attach.md), [`research/decisions/decision-013-host-neutral-multi-host-layout.md`](research/decisions/decision-013-host-neutral-multi-host-layout.md).

## Architecture

Definitions: [`docs/architecture.md`](docs/architecture.md). Operating notes: [`AGENTS.md`](AGENTS.md). Conflicts: [`docs/precedence.md`](docs/precedence.md).

```text
Rules constrain → Skills provide methods → Commands start work
 → Agents isolate roles → Verification / review-loop check
 → Lessons → Knowledge
```

**Profiles** add personal context and are not created yet (`knowledge/personal/` holds background). **Adapters** map the canonical core onto Cursor, Codex, Claude Code, and Antigravity; they must not fork meaning. **Optional model preferences** live in Git-ignored `~/.b3/models.md` (and optional `<project>/.b3/models.md`) copied from [`config/models.example.md`](config/models.example.md) (`docs/model-preferences.md`).

## Research → knowledge → skills

```text
External sources → research/ → knowledge/ → skills / rules / workflows
```

`research/` is intake plus `validation/` evidence. `knowledge/` is what the system knows. Skill `references/` are task aids. Method: [`docs/research-methodology.md`](docs/research-methodology.md). Evolution: [`docs/system-lifecycle.md`](docs/system-lifecycle.md). Lessons do **not** automatically become rules.

## Standalone commands, review & review loop

- **Standalone operations** ([`commands/README.md`](commands/README.md)): `/b3-plan` (risk-adaptive scoped plans, AC-to-check mapping, plan-only stop), `/b3-implement` (single-hop via [`problem-solving`](skills/engineering/problem-solving/SKILL.md) with `b3-guard` checks, risk-sensitive specialists, and max 2 bounded fix-verify rounds without escalating to `/b3-ship`), `/b3-debug` (broken invariant, sibling sweep, regression test, 3-attempt stop/escalate), and `/b3-verify` (`b3-guard verify-run`/`verify-check` `b3-verify-v1` provenance receipts with `-ExpectedCmd` & `-RelevantPaths` coverage).
- **Single-pass `/b3-review`** ([`commands/b3-review.md`](commands/b3-review.md) / [`skills/engineering/code-review/SKILL.md`](skills/engineering/code-review/SKILL.md)): supports **3 modes** — **local diff/branch** (delta-first/scope-first via `b3-guard diff-scope` + `mechanical-check` `safety_hits` + `symbol-check` on refactors, plus `verify-check` / CI evidence validation), **GitHub PR (`#<id>` / URL)** with noise filtering before pulling diffs, and **optional PR commenting/inline reviews** (`--body-file` / `gh api .../reviews --input`, `COMMENT` default, `CONFIRMED` findings only) via progressive-disclosure [`skills/engineering/code-review/references/github-pr-review.md`](skills/engineering/code-review/references/github-pr-review.md).
- **Iterative `/b3-review-loop`** ([`commands/b3-review-loop.md`](commands/b3-review-loop.md)): runtime-self-sufficient [`review-loop/strategy.md`](review-loop/strategy.md) (skips `spec.md`/`sizing.md`/`models.md` on normal runs), 0-token `diff-scope` + `mechanical-check` + `symbol-check`, Iteration 2+ `--prev-sha` `delta_files`, `impl_agent` prompt-cache resume (or fresh `b3-fixer` + compact `.b3/ship/review-loop/<slug>/` state when run standalone without `/b3-ship`), `verify-run`/`verify-check` gate, bug-class sweep, 2-tier circuit breaker, and explicit `review_independence: SINGLE_AGENT_LIMIT` honesty when host lacks subagent isolation. Normative references: [`review-loop/spec.md`](review-loop/spec.md), [`review-loop/models.md`](review-loop/models.md).

## Full lifecycle (`/b3-ship`)

One invocation runs `Preflight → Plan → [Scope → Build → Verify → Review → Commit] → Finalize` (with verbatim shared contracts, risk-adaptive `detailed` matrices `failure_matrix` / `write_paths` / `io_budget`, disjoint **Parallel Waves** via `b3-guard check-wave -WaveReads -ExpectedBaseSha` + `check-worktree`, `impl_agent` Context Packets, Hub-and-Spoke `discoveries`/`change_requests`, 0-token `mechanical-check` `safety_hits` + `symbol-check`, `verify-run` / `verify-check` (`b3-verify-v1`) receipts enforced by `precommit -RequireVerifyReceipt`, risk-tiered independent review with portable 4-tier escalation, sequential atomic commits, and Git-verified resume with read-only `.b3/autodev/` legacy fallback). Procedure: [`workflows/ship.md`](workflows/ship.md) (progressive-disclosure templates & resume under `workflows/references/`). Guard CLI: [`scripts/README.md`](scripts/README.md). Command: [`commands/b3-ship.md`](commands/b3-ship.md) (1-hop `adapters/command-skills/b3-ship/SKILL.md` for skill-based hosts). Run-scoped checkpoints live under `.b3/ship/runs/<run_id>/` via 1-line `.b3/ship/CURRENT` (gitignored).

**Visual diagrams & walkthrough:** [`docs/ship-and-review-guide.md`](docs/ship-and-review-guide.md) (Mermaid flowcharts & sequence diagrams for `/b3-ship`, Parallel Waves, `/b3-review-loop`, and 3-mode `/b3-review`).

## Context budget & validation

Static always-on, `/b3-ship`, `/b3-review-loop`, `review_delta_load`, and standalone command (`standalone_cmds`) byte/token budgets are tracked identically across shells by [`scripts/measure-context.ps1`](scripts/measure-context.ps1) / [`scripts/measure-context.sh`](scripts/measure-context.sh) (`-Strict` / `--strict`). Behavioral (`validate-ship-behavior.ps1`, `validate-standalone-commands.ps1`), isolated product smoke (`smoke-ship-product.ps1`), and eval schema (`validate-evals.sh`) checks are cataloged in [`scripts/README.md`](scripts/README.md).

## Evaluation

262 YAML schema/activation fixtures live under `evals/` (including `evals/commands/` and `evals/workflows/ship/`), validated with [`scripts/validate-evals.sh`](scripts/validate-evals.sh); automated LLM scoring runner remains deferred. Behavioral CLI suites run via `scripts/validate-standalone-commands.ps1`, `scripts/validate-ship-behavior.ps1`, and `scripts/smoke-ship-product.ps1`. Layout: [`docs/evaluation.md`](docs/evaluation.md).

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
| Full lifecycle (`/b3-ship`) | Present as workflow + `commands/b3-ship.md` + `adapters/command-skills/b3-ship/` |
| Knowledge after lessons | Minimal (`knowledge/personal/` only) |
| Profile files | Not created (`knowledge/personal/` holds background) |
| Cursor / Codex / Claude / Antigravity adapters | Present (`sync-skills`, `install-product`, Antigravity plugin); live runtime host discovery **UNKNOWN / INCOMPLETE** |

**Present rules:** `engineering-principles`, `verification`, `portability`, `evidence-and-provenance`, `simplest-correct`.
