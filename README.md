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

Full per-host setup, coexistence guards, native binary distribution, and manual smoke checklists live in [`adapters/README.md`](adapters/README.md) (`adapters/{cursor,codex,claude,antigravity}/README.md`).

- **Native CLI (`b3`):** Build from source with `cargo build --release` (`target/release/b3.exe` / `b3`) or download a checksum-verified release binary via `./scripts/bootstrap-b3.{ps1,sh}` (`--rollback` restores `.prev`). Subcommands: `b3 guard <cmd>`, `b3 pr <cmd>`, `b3 sync`, `b3 install <product|cursor|antigravity|global>`, and `b3 context measure`. End users need only `git` (and optional `gh` for PR commands); wrappers in `{scripts,adapters}/*.{ps1,sh}` forward to `b3` automatically (`B3_BIN` or `target/release/b3*`).
- **Machine-global install (Cursor & Antigravity):** `./adapters/install-global.ps1 -HostName <cursor|antigravity|all>` (or `b3 install global --host <...>`; actions `install`, `verify`, `update`, `uninstall`; supports `-DryRun`/`-Force`). Unified `install`/`update` initializes missing `~/.b3/models.md` from [`config/models.example.md`](config/models.example.md) (`docs/model-preferences.md`). Direct installers: `adapters/cursor/install-global.{ps1,sh}`, `adapters/antigravity/install-plugin.{ps1,sh}`.
- **Inside this B3 checkout:**
  - Cursor / Codex / Claude Code: `b3 sync --host <cursor|codex|claude>` (or `./adapters/sync-skills.{ps1,sh} <cursor|codex|claude>`) creates gitignored local links without mixing conflicting discovery roots.
  - Antigravity: root `AGENTS.md` + committed `.agents/skills.json` work directly (`b3 sync --host antigravity --verify-only`).
- **Attach a separate product repo:** `b3 install product --product-root <product-root> --host <host>` (or `./adapters/install-product.{ps1,sh}`) writes `.b3/home` + thin host bridge/links without copying `skills/` ([`decision-011`](research/decisions/decision-011-product-repo-attach.md), [`decision-013`](research/decisions/decision-013-host-neutral-multi-host-layout.md)).

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

- **Standalone commands** ([`commands/README.md`](commands/README.md), `11` commands): `/b3-plan`, `/b3-implement`, `/b3-debug`, `/b3-verify`.
- **Single-pass `/b3-review`** ([`commands/b3-review.md`](commands/b3-review.md) / [`code-review/SKILL.md`](skills/engineering/code-review/SKILL.md)): local diff/branch review, read-only GitHub PR inspection, or optional `--post` via [`pr-feedback/SKILL.md`](skills/engineering/pr-feedback/SKILL.md).
- **PR feedback (`/b3-pr-resolve`, `/b3-pr-reply`, `/b3-pr-comment`)** ([`pr-feedback/SKILL.md`](skills/engineering/pr-feedback/SKILL.md)): single-writer PR thread/comment lifecycle via native `b3 pr` (`scripts/b3-pr-github.{ps1,sh}`).
- **Iterative `/b3-review-loop`** ([`review-loop/strategy.md`](review-loop/strategy.md)): self-sufficient loop orchestrator; normative contracts in [`review-loop/spec.md`](review-loop/spec.md) and [`review-loop/models.md`](review-loop/models.md).

## Full lifecycles (`/b3-ship` & `/b3-research-ship`)

- **`/b3-ship`** ([`workflows/ship.md`](workflows/ship.md)): `Preflight → Plan → [Scope → Build → Verify → Review → Commit] → Finalize` with `b3-guard` checks, 4-mode parallel waves, `b3-verify-v1` receipts, risk-tiered independent review, and atomic commits (checkpoints in gitignored `.b3/ship/runs/<run_id>/`).
- **`/b3-research-ship`** ([`workflows/research-ship.md`](workflows/research-ship.md)): research-first Phases A–K with SHA-256 source provenance (`evidence-check`), dual Research/Engineering/Editorial gates, and provider-neutral `merge-policy-check` under gitignored `.b3/research-ship/runs/<run_id>/`.
- **Diagrams & walkthrough:** [`docs/ship-and-review-guide.md`](docs/ship-and-review-guide.md). CLI catalog: [`scripts/README.md`](scripts/README.md).

## Context budget, validation & evaluation

- **Static budgets & routing:** [`scripts/measure-context.{ps1,sh}`](scripts/measure-context.ps1) (`--strict`) enforces static context caps; conditional MCP routing (`0 B` always-on) is documented in [`docs/context-routing.md`](docs/context-routing.md).
- **Behavioral & eval suites:** all validation scripts (`validate-*`, `smoke-ship-product.ps1`, `validate-evals.sh`) and CLI guards are cataloged in [`scripts/README.md`](scripts/README.md); fixture structure and `299` YAML schema cases live under `evals/` ([`evals/README.md`](evals/README.md), [`docs/evaluation.md`](docs/evaluation.md)).

## Personal profile & platforms

- Background: [`knowledge/personal/engineering-context.md`](knowledge/personal/engineering-context.md) (personal preference != rule; `profiles/` stays uncreated).
- 4-host canonical mapping matrix: [`adapters/README.md`](adapters/README.md).

## Maturity & governance

System evolution, promotion gates, the canonical maturity table, and single-source ownership boundaries live in [`docs/system-lifecycle.md`](docs/system-lifecycle.md).

**Present rules:** `engineering-principles`, `verification`, `portability`, `evidence-and-provenance`, `simplest-correct`.
