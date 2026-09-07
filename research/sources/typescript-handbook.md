# TypeScript Handbook (official docs)

## Source

https://www.typescriptlang.org/docs/handbook/intro.html

## Tier

Tier 1

## Purpose

Official TypeScript learning path: static typechecking for JavaScript, handbook vs reference split.

## Architecture

- **Handbook**: narrative guide for everyday programmers (not full language spec)
- **Reference**: formal, edge-case behavior per concept
- **Non-goals**: bundler/framework setup (webpack, React, etc.) out of scope

## Important Patterns

- Type errors as primary failure class TS addresses
- Read handbook top-down for concepts; reference for precise behavior
- Compiler options affect behavior — handbook explains important flags
- TS augments JS; does not replace runtime semantics knowledge

## Skill Design

TypeScript guidance for agents should emphasize:
- **When to reach for types** vs `any` escape hatches
- **Narrowing and generics** for API boundaries
- **Compiler option awareness** (`strict`, etc.) without duplicating reference

Avoid a skill that re-teaches entire handbook — use progressive disclosure to official reference links.

## Rules / Instructions

`strict` and project `tsconfig` belong in **repo rules**, not portable core — unless documenting personal defaults in profile.

## Agents

N/A

## Commands / Workflows

N/A

## Evaluation

No agent evals. Typecheck (`tsc`) is verification evidence.

## Portability

High — TS applies across frontend/backend Node. Good candidate for cross-cutting **engineering** references, not always a standalone skill.

## Strengths

- Clear handbook vs reference separation matches progressive disclosure
- Honest about non-goals (no bundler recipes)

## Weaknesses / Trade-offs

- Handbook not exhaustive for edge cases
- Framework integration deferred to external docs

## Interesting Implementation Details

- Multiple "TS for X programmers" intros for audience routing

## Relevant Files

- typescriptlang.org/docs/handbook/**
- typescriptlang.org/docs/handbook/reference.html

## Evidence

- Fetched 2026-09-07: handbook purpose, structure, non-goals, type-error focus

## Relevance to b3-ai-engineering

TypeScript patterns likely **embed in frontend/backend skills** as references rather than a fourth foundation skill. Separate skill only if trigger evals show distinct activation (e.g. "fix these type errors").

## Initial Recommendation

ADAPT — reference slices in domain skills; optional small `typescript-boundaries` skill after synthesis if near-miss evals require it
