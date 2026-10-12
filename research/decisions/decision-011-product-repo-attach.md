# Decision 011 — Attach B3 to a product repository

## Context

Autonomous development v1 assumed the agent’s cwd was the B3 system repo. Skills, commands, and workflows used B3-relative paths. A product repository cannot follow those paths. Copying `.cursor/skills` into the product would duplicate Cursor discovery.

## Options considered

1. Copy the B3 skill/command tree into every product repo.
2. Thin pointer: `{product}/.b3/home` + `{product}/.cursor/commands/autodev.md`; load meaning from `B3_HOME`.
3. Git submodule of the whole B3 repo.

## Decision

**ADOPT option 2. REJECT option 1. DEFER option 3.**

Installer: `adapters/install-product.ps1` / `.sh`. Template: `adapters/product-autodev.md`.

Cursor install must not create `.agents/skills` or `.claude/skills` in the product. Codex/Claude may junction those paths to `B3_HOME/.cursor/skills`.

## Consequences

- Workflow resolves `B3_HOME` then `PRODUCT_ROOT`.
- Product `.gitignore` must ignore `.b3/`.
- User-level Cursor skill copies remain the user’s choice; the installer must not add a second project copy.

## Confidence

High on layering. Product-repo slash-command discovery is **NOT VERIFIED** until a host session in an installed product repo lists `/autodev`.
