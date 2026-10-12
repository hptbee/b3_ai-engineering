# b3-ai-engineering

A personal AI-assisted software engineering system. **Cursor is the first host and Codex is now supported.** The conceptual core (Agent Skills, rules, review-loop, evals, research) stays portable; thin host adapters map it onto each product.

This is an **evolving** operating layer for AI coding agents. It is not a company handbook.

## Repository layout

```text
b3-ai-engineering/
├── AGENTS.md                 Cross-host always-on map (Cursor and Codex read this)
├── README.md                 Human-facing entry
├── .cursor/
│   ├── rules/                Cursor rule activation (.mdc → portable rules/)
│   ├── skills/               Canonical skills (Agent Skills SKILL.md)
│   ├── commands/             User-facing / actions
│   └── agents/               Reviewer / fixer subagents
├── rules/                    Portable rule bodies (source of meaning)
├── workflows/                Default product sequence
├── review-loop/              Spec + orchestration procedure
├── knowledge/                Reusable internal knowledge
├── research/                 Provenance
├── evals/                    Fixtures (not a runner)
├── adapters/                 Other-host mapping + cross-platform export helpers
├── scripts/                  Repository tooling
└── docs/                     Architecture, standards, contracts
```

Catalogs: [`.cursor/skills/README.md`](.cursor/skills/README.md), [`docs/architecture.md`](docs/architecture.md). What Cursor loads: [`AGENTS.md`](AGENTS.md).

## Why it exists

Agents are useful when they have durable constraints, reusable methods, verification instead of assertion, a way to learn without turning preference into dogma, and a core whose **meaning** is not rewritten per product.

## Cursor and Codex, portable meaning

Skills are Agent Skills (`SKILL.md`) stored canonically under `.cursor/skills/`; Codex discovers the same files through a local `.agents/skills` junction or symlink. Rule **bodies** stay in `rules/*.md`; Cursor activates them with `.cursor/rules/*.mdc`, while Codex receives durable cross-host constraints through `AGENTS.md`. Cursor commands/agents remain native. Codex uses explicit prompt routing and delegated role prompts because no repository custom-agent or slash-command surface is established here.

Evidence over opinion. Progressive disclosure. Small composable skills. Research, then adapt — do not copy skill packs.

## Installation

Host-specific notes: [`adapters/cursor/README.md`](adapters/cursor/README.md), [`adapters/codex/README.md`](adapters/codex/README.md), [`adapters/claude/README.md`](adapters/claude/README.md).

### Cursor

**Work inside this B3 repository:** Clone and open the repo root in Cursor. `.cursor/rules`, `.cursor/skills`, `.cursor/commands` (including `/autodev`), and `.cursor/agents` are committed and discovered from the project. `AGENTS.md` loads as the cross-host map. No adapter script is required.

Do **not** run `sync-skills` for Cursor in this repo — skills already live at `.cursor/skills`. Do **not** add `.agents/skills` or `.claude/skills` here; Cursor would load duplicate skills.

**Work in a separate product repository:**

1. From **this B3 clone**, attach the product (run on your machine; paths are examples):

```powershell
# Windows
.\adapters\install-product.ps1 -ProductRoot D:\path\to\your-product -HostName cursor
```

```bash
# macOS / Linux
./adapters/install-product.sh --product-root /path/to/your-product --host cursor
```

Optional: `-B3Home` / `--b3-home` if this B3 checkout is not the parent of `adapters/`.

2. Open the **product** folder in Cursor (not only the B3 repo).
3. Invoke `/autodev`; the workflow resolves this B3 clone via `{product}/.b3/home` or the `B3_HOME` environment variable.

The installer writes `{product}/.b3/home`, a thin `{product}/.cursor/commands/autodev.md`, and a `.b3/` line in `.gitignore`. It does **not** copy `.cursor/skills` into the product. Commit `.b3/home`, `.cursor/commands/autodev.md`, and any `.gitignore` change. Checkpoints under `.b3/autodev/` stay local and gitignored.

To use B3 **engineering skills** while the Agent works in the product (optional, once per machine), link user-level Cursor skills to this clone. Do not combine this with a copied skill tree under `{product}/.cursor/skills`.

```powershell
# Windows — replace the target with your B3 clone
$skills = 'D:\Project\b3_ai-engineering\.cursor\skills'
$dest = Join-Path $env:USERPROFILE '.cursor\skills\b3-ai-engineering'
New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
if (-not (Test-Path -LiteralPath $dest)) { cmd /c mklink /J "$dest" "$skills" }
```

```bash
# macOS / Linux
ln -sfn /path/to/b3_ai-engineering/.cursor/skills ~/.cursor/skills/b3-ai-engineering
```

Product-only rules and commands stay in the product’s own `.cursor/` tree; portable rule bodies remain in this B3 repo under `rules/`.

### Codex (this B3 checkout)

Create the local skill link (gitignored):

```powershell
.\adapters\sync-skills.ps1 -HostName codex
.\adapters\sync-skills.ps1 -HostName codex -VerifyOnly
```

```bash
./adapters/sync-skills.sh codex
./adapters/sync-skills.sh --verify codex
```

If `.agents/skills` is an empty folder and the script fails with “access denied”, close Cursor windows on this repo and retry, or remove that directory, then run the helper again.

On a **product repo**, use `install-product` with `--host codex` so the installer may add a gitignored `.agents/skills` → `B3_HOME/.cursor/skills` and a thin product `AGENTS.md` if missing. Cursor also discovers `.agents/skills`; do not combine that link with a copied skill tree under `{product}/.cursor/skills`.

### Claude Code (this B3 checkout)

When you use Claude Code from this repo and not alongside Cursor in the same tree:

```powershell
.\adapters\sync-skills.ps1 -HostName claude
```

```bash
./adapters/sync-skills.sh claude
```

On a product repo without Cursor, `install-product` with `--host claude` may add `.claude/skills` → `B3_HOME/.cursor/skills`. Cursor product install refuses product `.agents/skills` / `.claude/skills` to avoid duplicate discovery.

More detail: [`adapters/README.md`](adapters/README.md), [`research/decisions/decision-011-product-repo-attach.md`](research/decisions/decision-011-product-repo-attach.md).

## Architecture

Definitions: [`docs/architecture.md`](docs/architecture.md). Operating notes: [`AGENTS.md`](AGENTS.md). Conflicts: [`docs/precedence.md`](docs/precedence.md).

```text
Rules constrain → Skills provide methods → Commands start work
 → Agents isolate roles → Verification / review-loop check
 → Lessons → Knowledge
```

**Profiles** add personal context and are not created yet (`knowledge/personal/` holds background). **Adapters** export to Codex/Claude; they must not fork meaning.

## Research → knowledge → skills

```text
External sources → research/ → knowledge/ → skills / rules / workflows
```

`research/` is intake plus `validation/` evidence. `knowledge/` is what the system knows. Skill `references/` are task aids. Method: [`docs/research-methodology.md`](docs/research-methodology.md). Evolution: [`docs/system-lifecycle.md`](docs/system-lifecycle.md). Lessons do **not** automatically become rules.

## Review loop

Specified in [`review-loop/spec.md`](review-loop/spec.md). Orchestration: [`review-loop/strategy.md`](review-loop/strategy.md). Invoke: [`.cursor/commands/review-loop.md`](.cursor/commands/review-loop.md). Host model slots: `review-loop/models.md`.

## Autonomous development

One invocation runs plan (when needed), implementation, the review loop, focused commits, and resume. Procedure: [`workflows/autonomous-development.md`](workflows/autonomous-development.md). Cursor: [`.cursor/commands/autodev.md`](.cursor/commands/autodev.md). Codex and Claude use the same file through prompt routing (`adapters/`). Checkpoints live in the repo under change at `.b3/autodev/` (gitignored). Product-repo setup: [Installation](#installation). A stopped session does not resume until the user invokes the workflow again.

## Evaluation

Activation fixtures live under `evals/`. Automated runner deferred. Layout: [`docs/evaluation.md`](docs/evaluation.md).

## Personal profile

Background: [`knowledge/personal/engineering-context.md`](knowledge/personal/engineering-context.md). A `profiles/` directory is **not created** until Tùng records it.

```text
Personal preference  ≠  Engineering rule
```

## Platforms

```text
Portable meaning  →  .cursor/ (this repo)  →  Cursor
                  →  adapters/ (Codex, Claude) when those hosts are used
```

## Current maturity

| Area | Status |
| --- | --- |
| Architecture, standards, precedence, lifecycle | Present |
| Foundation rules + Cursor `.mdc` activation | Present |
| Engineering + domain skills | Present (see `.cursor/skills/README.md`) |
| Commands, agents | Present (Cursor-native, thin) |
| Eval fixtures | Present; runner deferred |
| Review-loop orchestration | Present (agent procedure; Codex prompt-routed and delegated; product isolation **UNKNOWN / INCOMPLETE**) |
| Autonomous development | Present as workflow + `/autodev` (decision-010). Cursor slash UX **INTENDED**. Codex and Claude runtime **NOT TESTED** |
| Knowledge after lessons | Minimal (`knowledge/personal/` only) |
| Profile files | Not created (`knowledge/personal/` holds background) |
| Codex adapter | Implemented through local .agents/skills link; discovery remains UNKNOWN / INCOMPLETE in the current checkout (see research/validation/codex-host-v1.md) |

**Present rules:** `engineering-principles`, `verification`, `portability`, `evidence-and-provenance`, `simplest-correct`.
