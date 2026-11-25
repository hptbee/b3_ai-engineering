# b3-ai-engineering

A personal AI-assisted software engineering system built on a **host-neutral canonical core** supporting **Cursor**, **Codex**, **Claude Code**, and **Antigravity**. The conceptual core (`24` canonical Agent Skills + `11` command-skills = `35` total `SKILL.md` files, `5` rules, `11` commands, `5` agents, workflows, review-loop, `299` eval fixtures, research) stays portable and provider-neutral; thin host wrappers and adapters map it onto each product without duplicating prose.

This is an **evolving** operating layer for AI coding agents. It is not a company handbook.

## Repository layout

```text
b3-ai-engineering/
├── AGENTS.md                 Universal always-on map (Cursor, Codex, Antigravity)
├── CLAUDE.md                 Thin @AGENTS.md bridge (Claude Code)
├── README.md                 Human-facing entry
├── rules/                    Portable rule bodies (source of meaning)
├── skills/                   24 canonical skills (Agent Skills SKILL.md)
├── commands/                 11 canonical user-facing /b3-* actions
├── agents/                   5 canonical reviewer / fixer subagent specs
├── workflows/                Default product sequence, /b3-ship & /b3-research-ship lifecycles
├── review-loop/              Spec + orchestration procedure
├── knowledge/                Reusable internal knowledge
├── research/                 Provenance & architecture decisions
├── evals/                    299 YAML fixtures (not a runner)
├── adapters/                 4-host adapters, 11 command-skills & installers
├── .cursor/rules/            Committed thin Cursor .mdc wrappers (@rules/*.md)
├── .agents/skills.json       Committed Antigravity 1-level skill manifest
├── scripts/                  Provider-neutral guards, optional GitHub adapters & validation
├── config/                   Optional Markdown model preference example (models.example.md)
└── docs/                     Architecture, standards, contracts
```

Catalogs: [`skills/README.md`](skills/README.md), [`docs/engineering-philosophy.md`](docs/engineering-philosophy.md), [`docs/architecture.md`](docs/architecture.md), [`docs/model-preferences.md`](docs/model-preferences.md), [`docs/context-routing.md`](docs/context-routing.md). Universal map: [`AGENTS.md`](AGENTS.md).

## Why it exists

Agents are useful when they have durable constraints, reusable methods, verification instead of assertion, a way to learn without turning preference into dogma, and a core whose **meaning** is not rewritten per product.

## Host-neutral core, 4-host activation

Skills are Agent Skills (`SKILL.md`) stored canonically under `skills/` (`24` domain & engineering skills) plus `11` thin `adapters/command-skills/` (`35` total `SKILL.md` files), commands under `commands/` (`11` `/b3-*` actions), subagent roles under `agents/` (`5` roles), and rule bodies under `rules/`. Each host consumes that single source of truth through thin committed entrypoints (`.cursor/rules/*.mdc`, `CLAUDE.md`, `.agents/skills.json`) and/or gitignored local links managed by `adapters/sync-skills.{ps1,sh}` and `adapters/install-product.{ps1,sh}`.

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

**Optional personal models:** Unified global `install`/`update` initializes a missing `~/.b3/models.md` using [`config/models.example.md`](config/models.example.md). Existing preferences are never overwritten; dry-run, verify and uninstall do not modify them. Direct host installers require copying the example manually. See [`docs/model-preferences.md`](docs/model-preferences.md) (`-UserHome`, `B3_MODELS_PERSONAL`, `B3_SKIP_MODEL_INIT`).

Details, project overrides, and manual host runtime smoke checklists: [`adapters/cursor/README.md`](adapters/cursor/README.md), [`adapters/antigravity/README.md`](adapters/antigravity/README.md).

### Cursor

**Global one-time install:** makes all `11` commands, flattened 1-level skills (`24` canonical skills), `5` subagents, global `b3-home`, and a compact `b3-user-rules.txt` User Rules template available under `~/.cursor/` (or via `.\adapters\install-global.ps1 -HostName cursor`):

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

**Inside this B3 checkout:** Create the local flattened `.agents/skills/<name>` index (`35` skills = `24` core `skills/` + `11` `adapters/command-skills/`):

```powershell
.\adapters\sync-skills.ps1 -HostName codex
.\adapters\sync-skills.ps1 -HostName codex -VerifyOnly
```

```bash
./adapters/sync-skills.sh codex
./adapters/sync-skills.sh --verify codex
```

**Separate product repo:** Use `install-product` with `-HostName codex` / `--host codex`. That writes `.b3/home`, a thin `AGENTS.md` if missing, and a gitignored flattened `.agents/skills/<name>` index so Codex can invoke `$b3-ship` (and `$b3-plan`, `$b3-implement`, `$b3-pr-resolve`, …).

### Claude Code

**Inside this B3 checkout:** Root `CLAUDE.md` (`@AGENTS.md`) is committed and works on fresh clone. Create the local gitignored `.claude/skills/<name>` (`35` skills = `24` core `skills/` + `11` `adapters/command-skills/`, unified slash commands as skills) and `.claude/agents` links:

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

- **Inside this B3 checkout:** Root `AGENTS.md` and committed `.agents/skills.json` (1-level category entries over `skills/*` plus `adapters/command-skills`, exposing all `35` `SKILL.md` entries) work out of the box without creating a `.agents/skills` link. Verify with:

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

- **Machine-global plugin:** Manage `~/.gemini/config/plugins/b3-ai-engineering/` (rules, 1-level skill links, `11` command skills, and isolated `agents/*.md` subagents; or use `.\adapters\install-global.ps1 -HostName antigravity`) via:

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

- **Standalone operations** ([`commands/README.md`](commands/README.md), `11` commands total): `/b3-plan` (risk-adaptive scoped plans, AC-to-check mapping, plan-only stop), `/b3-implement` (single-hop via [`problem-solving`](skills/engineering/problem-solving/SKILL.md) with `b3-guard` checks, risk-sensitive specialists, and max 2 bounded fix-verify rounds without escalating to `/b3-ship`), `/b3-debug` (broken invariant, sibling sweep, regression test, 3-attempt stop/escalate), and `/b3-verify` (`b3-guard verify-run`/`verify-check` `b3-verify-v1` provenance receipts with `-ExpectedCmd` & `-RelevantPaths` coverage).
- **Single-pass `/b3-review`** ([`commands/b3-review.md`](commands/b3-review.md) / [`skills/engineering/code-review/SKILL.md`](skills/engineering/code-review/SKILL.md)): supports **3 modes** — **local diff/branch** (delta-first/scope-first via `b3-guard diff-scope` + `mechanical-check` `safety_hits` + `symbol-check` on refactors, plus `verify-check` / CI evidence validation), **GitHub PR (`#<id>` / URL)** with noise filtering before pulling diffs, and **optional authorized PR posting (`--post`)** delegated to [`skills/engineering/pr-feedback/SKILL.md`](skills/engineering/pr-feedback/SKILL.md) + `scripts/b3-pr-github.{ps1,sh}` (`COMMENT` default, `CONFIRMED` findings only).
- **PR feedback lifecycle (`/b3-pr-resolve`, `/b3-pr-reply`, `/b3-pr-comment`)** ([`skills/engineering/pr-feedback/SKILL.md`](skills/engineering/pr-feedback/SKILL.md)): end-to-end thread triage/fix/verify/reply/resolve, evidence-backed reply-only mode, and SHA-fresh review publication (`summary`, `inline`, `both`, `--draft`) via `scripts/b3-pr-github.{ps1,sh}` (sharing `scripts/lib/b3-gh-exec.mjs` with `b3-github-verify`) with canonical `<git-common-dir>/b3/pr-feedback/` per-repo/PR state & PID locks (shared across linked worktrees; `.b3/pr-feedback/` is gitignored local scratch only), untrusted-data framing, separate authorizations, actor-scoped idempotency, and Research Ship governance separation.
- **Iterative `/b3-review-loop`** ([`commands/b3-review-loop.md`](commands/b3-review-loop.md)): runtime-self-sufficient [`review-loop/strategy.md`](review-loop/strategy.md) (skips `spec.md`/`sizing.md`/`models.md` on normal runs), 0-token `diff-scope` + `mechanical-check` + `symbol-check`, Iteration 2+ `--prev-sha` `delta_files`, `context-cache` (`AnchorPaths` stable contract hash vs `ScopePaths` graph-index scope), `impl_agent` prompt-cache resume (or fresh `b3-fixer` + compact `.b3/ship/review-loop/<slug>/` state when run standalone without `/b3-ship`), `verify-run`/`verify-check` gate, bug-class sweep, 2-tier circuit breaker, and explicit `review_independence: SINGLE_AGENT_LIMIT` honesty when host lacks subagent isolation. Normative references: [`review-loop/spec.md`](review-loop/spec.md), [`review-loop/models.md`](review-loop/models.md).

## Full lifecycles (`/b3-ship` & `/b3-research-ship`)

One `/b3-ship` invocation runs `Preflight → Plan → [Scope → Build → Verify → Review → Commit] → Finalize` with verbatim shared contracts, risk-adaptive `detailed` matrices (`failure_matrix` / `write_paths` / `io_budget`), automatic 4-mode **Parallel Waves** (`SHARED_READ_ONLY`, `SHARED_DISJOINT_WRITES`, `ISOLATED_WRITES`, `SEQUENTIAL`) via `b3-guard check-wave -Partition` (`WAVE_OK` / `WAVE_PARTITIONED` / `WAVE_SEQUENTIAL`, `wave|N|...`, `-WaveReads`, `-ProtectedPaths`, `-CheckDirtyScope`, `-MaxConcurrency 1..4`, `none`/`[]` readers) + `check-worktree -RequireIsolated -PeerRoots`, `impl_agent` Context Packets, Hub-and-Spoke `discoveries`/`change_requests`, 0-token `mechanical-check` (`-WaveSpecs`, `-WorkerChanges` / `-WorkerRoots`, `-ProtectedPaths`, `-DirtyDigests` → `ownership_verification` ∈ `UNVERIFIED_COMBINED_ONLY | CALLER_ATTRIBUTED | PARTIAL_ATTRIBUTION | VERIFIED_PER_WORKER | VIOLATION`) + `symbol-check`, `verify-run` / `verify-check` (`b3-verify-v1`) receipts enforced by `precommit -RequireVerifyReceipt`, risk-tiered independent review with portable 4-tier escalation, sequential atomic commits, and Git-verified resume with read-only `.b3/autodev/` legacy fallback. Procedure: [`workflows/ship.md`](workflows/ship.md) (progressive-disclosure templates & resume under `workflows/references/`). Guard CLI: [`scripts/README.md`](scripts/README.md). Command: [`commands/b3-ship.md`](commands/b3-ship.md) (1-hop `adapters/command-skills/b3-ship/SKILL.md` for skill-based hosts). Run-scoped checkpoints live under `.b3/ship/runs/<run_id>/` via 1-line `.b3/ship/CURRENT` (gitignored).

Research-first delivery (`/b3-research-ship`) runs Phases A–K from source discovery and SHA-256 provenance manifests (`evidence-check`) through independent source verification, formalization, optional `/b3-ship` implementation, dual Research/Engineering/Editorial gates, PR lifecycle, and provider-neutral fail-closed `merge-policy-check` (`mode=local|github` bound to canonical trunk `.b3/research-policy.json` authority, `PR_READY` / `LOCAL_ELIGIBLE_ONLY` / `PROVIDER_UNAVAILABLE`, and `-PostMerge` local Git ancestry + optional `b3-github-verify`) under `.b3/research-ship/runs/<run_id>/`. Procedure: [`workflows/research-ship.md`](workflows/research-ship.md); command: [`commands/b3-research-ship.md`](commands/b3-research-ship.md) (1-hop `adapters/command-skills/b3-research-ship/SKILL.md`).

**Visual diagrams & walkthrough:** [`docs/ship-and-review-guide.md`](docs/ship-and-review-guide.md) (Mermaid flowcharts & sequence diagrams for `/b3-ship`, 4-mode Parallel Waves, `/b3-review-loop`, and 3-mode `/b3-review`).

## Context budget & validation

Static always-on, `/b3-ship`, `/b3-research-ship`, `/b3-review-loop`, `review_delta_load`, `context_routing`, and standalone command (`standalone_cmds`) byte/token budgets are tracked identically across shells by [`scripts/measure-context.ps1`](scripts/measure-context.ps1) / [`scripts/measure-context.sh`](scripts/measure-context.sh) (`-Strict` / `--strict`). Optional on-demand MCP-aware context routing (`0 B` always-on) is defined in [`workflows/references/context-routing.md`](workflows/references/context-routing.md) and documented in [`docs/context-routing.md`](docs/context-routing.md). Behavioral (`validate-ship-behavior.ps1`, `validate-standalone-commands.ps1`, `validate-pr-feedback.ps1`, `validate-merge-security.sh`, `validate-tshirt-hierarchical.ps1`, `validate-research-ship.ps1`, `validate-context-routing.ps1`, `validate-model-preferences.ps1`, `validate-cursor-global.ps1`, `validate-antigravity-global.ps1`), isolated product smoke (`smoke-ship-product.ps1`), and eval schema (`validate-evals.sh`) checks are cataloged in [`scripts/README.md`](scripts/README.md).

## Evaluation

`299` YAML schema/activation fixtures live under `evals/` (`176` in `evals/skills/`, `64` in `evals/workflows/` [`50` `ship` + `14` `research-ship`], `26` in `evals/review-loop/`, `16` in `evals/commands/`, `10` in `evals/rules/`, and `7` in `evals/agents/`), validated with [`scripts/validate-evals.sh`](scripts/validate-evals.sh); automated LLM scoring runner remains deferred. Behavioral CLI suites run via `scripts/validate-standalone-commands.ps1`, `scripts/validate-pr-feedback.ps1`, `scripts/validate-merge-security.sh`, `scripts/validate-ship-behavior.ps1`, `scripts/validate-research-ship.ps1`, `scripts/validate-context-routing.ps1`, `scripts/validate-tshirt-hierarchical.ps1`, `scripts/validate-model-preferences.ps1`, `scripts/validate-cursor-global.ps1`, `scripts/validate-antigravity-global.ps1`, and `scripts/smoke-ship-product.ps1`. Layout: [`docs/evaluation.md`](docs/evaluation.md).

## Personal profile

Background: [`knowledge/personal/engineering-context.md`](knowledge/personal/engineering-context.md). A `profiles/` directory is **not created** until Tùng records it.

```text
Personal preference  ≠  Engineering rule
```

## Platforms

```text
Canonical core (rules/, 24 skills/, 11 commands/, 5 agents/)
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
| Engineering + domain skills (`24` canonical + `11` command-skills = `35` `SKILL.md`) | Present (see [`skills/README.md`](skills/README.md)) |
| Commands (`11`), agents (`5`) | Present (host-neutral canonical core) |
| Eval fixtures (`299` YAML cases) | Present; runner deferred |
| Review-loop orchestration | Present (agent procedure; host isolation **UNKNOWN / INCOMPLETE**) |
| Full lifecycles (`/b3-ship`, `/b3-research-ship`) | Present as workflows + `commands/b3-{ship,research-ship}.md` + `adapters/command-skills/b3-{ship,research-ship}/` |
| PR feedback lifecycle (`/b3-pr-{resolve,reply,comment}`) | Present (`skills/engineering/pr-feedback/` + optional `scripts/b3-pr-github.{ps1,sh}`) |
| Knowledge after lessons | Minimal (`knowledge/personal/` only) |
| Profile files | Not created (`knowledge/personal/` holds background) |
| Cursor / Codex / Claude / Antigravity adapters | Present (`sync-skills`, `install-product`, `install-global`, Antigravity plugin); live runtime host discovery **UNKNOWN / INCOMPLETE** |

**Present rules:** `engineering-principles`, `verification`, `portability`, `evidence-and-provenance`, `simplest-correct`.
