# b3-ai-engineering

A personal AI-assisted software engineering system built on a **host-neutral canonical core** supporting **Cursor**, **Codex**, **Claude Code**, and **Antigravity**. The conceptual core (`24` canonical Agent Skills + `14` command-skills = `38` total `SKILL.md` files, `5` rules, `14` commands, `5` agents, workflows, review-loop, eval fixtures, research) stays portable and provider-neutral; thin host wrappers and adapters map it onto each product without duplicating prose.

This is an **evolving** operating layer for AI coding agents. It is not a company handbook. B3 currently optimizes host-executed engineering workflows; it does **not** include a standalone model/tool agent runtime. The [outcome-first roadmap](docs/roadmap.md) prioritizes verified work per total token/cost and a minimal boundary for future coding-agent CLIs without exposing private integration details.

## Documentation navigation

| Topic | Canonical documentation |
| --- | --- |
| What B3 is & System Architecture (Diagram A) | [`docs/architecture.md`](docs/architecture.md), [`docs/engineering-philosophy.md`](docs/engineering-philosophy.md) |
| Installation, 4-Host Compatibility & Sync (Diagram B) | [`adapters/README.md`](adapters/README.md) ([Cursor](adapters/cursor/README.md), [Codex](adapters/codex/README.md), [Claude](adapters/claude/README.md), [Antigravity](adapters/antigravity/README.md)) |
| Commands, Skills & Subagent Roles | [`commands/README.md`](commands/README.md), [`skills/README.md`](skills/README.md), [`agents/README.md`](agents/README.md) |
| Workflows, Adaptive Dispatch & Review Loop (Diagrams C–E) | [`docs/ship-and-review-guide.md`](docs/ship-and-review-guide.md), [`workflows/README.md`](workflows/README.md), [`review-loop/README.md`](review-loop/README.md) |
| Context Routing & Evidence Lifecycle (Diagram H) | [`docs/context-routing.md`](docs/context-routing.md), [`docs/model-preferences.md`](docs/model-preferences.md) |
| Native Guard Event Hooks (`b3 hook`) | [`docs/hooks.md`](docs/hooks.md), [`workflows/references/hook-integration.md`](workflows/references/hook-integration.md) |
| Evaluation & Benchmark Methodology (Diagram F) | [`docs/evaluation.md`](docs/evaluation.md), [`evals/README.md`](evals/README.md) |
| CI, Release Pipeline & Native CLI (Diagram G) | [`docs/ci-architecture.md`](docs/ci-architecture.md), [`scripts/README.md`](scripts/README.md) |
| Roadmap, Maturity, Ownership & Limitations | [`docs/roadmap.md`](docs/roadmap.md), [`docs/system-lifecycle.md`](docs/system-lifecycle.md), [`docs/precedence.md`](docs/precedence.md) |

## Repository layout

```text
b3-ai-engineering/
├── AGENTS.md                 Universal always-on map (Cursor, Codex, Antigravity)
├── CLAUDE.md                 Thin @AGENTS.md bridge (Claude Code)
├── README.md                 Human-facing entry
├── rules/                    Portable rule bodies (source of meaning)
├── skills/                   24 canonical skills (Agent Skills SKILL.md)
├── commands/                 14 canonical user-facing /b3-* actions
├── agents/                   5 canonical reviewer / fixer subagent specs
├── workflows/                Default product sequence, /b3-ship & /b3-research-ship lifecycles
├── review-loop/              Spec + orchestration procedure
├── knowledge/                Reusable internal knowledge
├── research/                 Provenance & architecture decisions
├── evals/                    YAML fixtures (not a runner)
├── adapters/                 4-host adapters, 14 command-skills & templates
├── scripts/                  Zero-Rust bootstrapper (bootstrap-b3.{ps1,sh}) & local CI preflight
├── config/                   Optional Markdown model preference example (models.example.md)
└── docs/                     Architecture, standards, contracts
```

Catalogs: [`skills/README.md`](skills/README.md), [`docs/engineering-philosophy.md`](docs/engineering-philosophy.md), [`docs/architecture.md`](docs/architecture.md), [`docs/model-preferences.md`](docs/model-preferences.md), [`docs/context-routing.md`](docs/context-routing.md). Universal map: [`AGENTS.md`](AGENTS.md).

## Why it exists

B3 makes existing coding agents more effective under practical model/context limits: fewer unnecessary tokens and retries, better task coordination, strong verification, and less manual intervention. Agents still benefit from durable constraints, reusable methods, evidence over assertion, and a core whose **meaning** is not rewritten per product.

**Current focus:** Compare active coding-agent hosts (**Cursor**, **Codex**, **Antigravity**) with B3 against the same host without B3 on identical verified tasks, then optimize only proven bottlenecks. **Future portability:** Keep canonical workflows and native Rust checks reusable by external coding-agent CLIs through opt-in adapters; do not build another IDE/agent loop by default. See [roadmap](docs/roadmap.md) and [evaluation method](docs/evaluation.md).

## Host-neutral core, 4-host activation

Skills are Agent Skills (`SKILL.md`) stored canonically under `skills/` (`24` domain & engineering skills) plus `14` thin `adapters/command-skills/` (`38` total `SKILL.md` files), commands under `commands/` (`14` `/b3-*` actions), subagent roles under `agents/` (`5` roles), and rule bodies under `rules/`. Each host consumes that single source of truth through `AGENTS.md` (and `CLAUDE.md` for Claude Code) plus gitignored activation files/links generated by the native `b3` CLI (`b3 sync`, `b3 install product`, `b3 install global`, `b3 install cursor`, `b3 install antigravity`).

Evidence over opinion. Progressive disclosure. Small composable skills. Research, then adapt — do not copy skill packs.

## Installation & Native CLI (`b3`)

Full per-host setup, coexistence guards, native binary distribution, and manual smoke checklists live in [`adapters/README.md`](adapters/README.md) (`adapters/{cursor,codex,claude,antigravity}/README.md`).

- **Sole zero-Rust bootstrapper (`bootstrap-b3.{ps1,sh}`):** End users only need [`scripts/bootstrap-b3.ps1`](scripts/bootstrap-b3.ps1) / [`scripts/bootstrap-b3.sh`](scripts/bootstrap-b3.sh) once to obtain `b3`. It downloads and verifies `SHA256SUMS.txt` from GitHub Releases (or `--release-dir` / `-ReleaseDir` offline bundles) and installs `b3` atomically (with `--rollback` / `-Rollback` to `.prev`) without requiring Rust, Cargo, Node.js, Python, PowerShell, or Bash at runtime.
- **Build from source (contributors):** `cargo build --release` produces `target/release/b3.exe` / `target/release/b3`.
- **Native subcommands:** `b3 guard <cmd>`, `b3 hook <install|uninstall|verify|status>`, `b3 pr <cmd>`, `b3 sync --host <host>`, `b3 install <product|cursor|antigravity|global>`, and `b3 context measure [--strict]`. End users need only `git` (and optional `gh` for PR commands).
- **Machine-global install (Cursor & Antigravity):**
  ```bash
  b3 install global --action install --host all
  # or per-host: b3 install cursor | b3 install antigravity
  # actions: install, verify, update, uninstall (supports --dry-run, --force)
  ```
  `b3 install global`, `b3 install product`, and `b3 sync` initialize missing `~/.b3/models.md` from [`config/models.example.md`](config/models.example.md) without overwriting existing preferences (`docs/model-preferences.md`).
- **Inside this B3 checkout:**
  - Cursor / Codex / Claude Code / Antigravity: `b3 sync --host <cursor|codex|claude|antigravity>` generates gitignored local activation links or `.agents/skills.json` without mixing conflicting discovery roots (`b3 sync --host <host> --verify-only` checks existing activation).
- **Attach a separate product repo:** `b3 install product --product-root <product-root> --host <host>` writes `.b3/home` + thin host bridge/links without copying `skills/` ([`decision-011`](research/decisions/decision-011-product-repo-attach.md), [`decision-013`](research/decisions/decision-013-host-neutral-multi-host-layout.md)).

- **Retired wrapper migration:** All 9 legacy PowerShell/Bash compatibility wrapper pairs were retired in favor of the single native `b3` CLI — see [`scripts/README.md`](scripts/README.md#retired-compatibility-wrappers) (`scripts/` wrappers) and [`adapters/README.md`](adapters/README.md#retired-adapter-compatibility-wrappers) (`adapters/` wrappers).

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

- **Standalone commands** ([`commands/README.md`](commands/README.md#practical-distinctions-and-examples), `7` core standalone of `14` total commands): `/b3-plan`, `/b3-implement`, `/b3-debug`, `/b3-research` (read-only Q&A/comparison; no research-ship state), `/b3-audit` (read-only baseline review of unchanged files; empty diff OK), `/b3-refactor` (scoped refactor/cleanup/measured optimization; no `/b3-ship` escalation), `/b3-verify`.
- **Single-pass `/b3-review`** ([`commands/b3-review.md`](commands/b3-review.md) / [`code-review/SKILL.md`](skills/engineering/code-review/SKILL.md)): local diff/branch review, read-only GitHub PR inspection, or optional `--post` via [`pr-feedback/SKILL.md`](skills/engineering/pr-feedback/SKILL.md) (use `/b3-audit` for unchanged-file baseline inspection).
- **PR feedback (`/b3-pr-resolve`, `/b3-pr-reply`, `/b3-pr-comment`)** ([`pr-feedback/SKILL.md`](skills/engineering/pr-feedback/SKILL.md)): single-writer PR thread/comment lifecycle via native `b3 pr <fetch|reconcile|reply|resolve|comment>`.
- **Iterative `/b3-review-loop`** ([`review-loop/strategy.md`](review-loop/strategy.md)): self-sufficient loop orchestrator; normative contracts in [`review-loop/spec.md`](review-loop/spec.md) and [`review-loop/models.md`](review-loop/models.md).

## Full lifecycles (`/b3-ship` & `/b3-research-ship`)

- **`/b3-ship`** ([`workflows/ship.md`](workflows/ship.md)): `Preflight → Plan → [Scope → Build → Verify → Review → Commit] → Finalize` with native `b3 guard` checks, 4-mode adaptive parallel waves ([`workflows/references/dispatch-naming.md`](workflows/references/dispatch-naming.md)), `b3-verify-v1` receipts, risk-tiered independent review, and atomic commits (checkpoints in gitignored `.b3/ship/runs/<run_id>/`).
- **`/b3-research-ship`** ([`workflows/research-ship.md`](workflows/research-ship.md)): research-first Phases A–K with SHA-256 source provenance (`b3 guard evidence-check`), dual Research/Engineering/Editorial gates, and provider-neutral `b3 guard merge-policy-check` under gitignored `.b3/research-ship/runs/<run_id>/`.
- **Diagrams & walkthrough:** [`docs/ship-and-review-guide.md`](docs/ship-and-review-guide.md). CLI catalog: [`scripts/README.md`](scripts/README.md).

## Context budget, validation & evaluation

- **Static budgets & routing:** `b3 context measure --strict` enforces static context caps; conditional MCP routing (`0 B` always-on) is documented in [`docs/context-routing.md`](docs/context-routing.md).
- **Behavioral & eval suites:** native Rust unit and integration tests run via `cargo test` (`tests/`); bootstrapper & preflight scripts and CLI reference live in [`scripts/README.md`](scripts/README.md), and YAML schema cases live under `evals/` ([`evals/README.md`](evals/README.md), [`docs/evaluation.md`](docs/evaluation.md)).

## Personal profile & platforms

- Background: [`knowledge/personal/engineering-context.md`](knowledge/personal/engineering-context.md) (personal preference != rule; `profiles/` stays uncreated).
- 4-host canonical mapping matrix: [`adapters/README.md`](adapters/README.md).

## Maturity & governance

The [canonical roadmap](docs/roadmap.md) defines priorities and phase exit evidence. System evolution, current maturity, promotion gates, and single-source ownership boundaries live in [`docs/system-lifecycle.md`](docs/system-lifecycle.md).

**Present rules:** `engineering-principles`, `verification`, `portability`, `evidence-and-provenance`, `simplest-correct`.
