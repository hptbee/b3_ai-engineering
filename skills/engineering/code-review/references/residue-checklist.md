# Simplification, overengineering & implementation residue checklist

Reference for [`../SKILL.md`](../SKILL.md) (local-diff simplification/residue; system-shape architecture belongs to `simplest-correct` / `b3-architecture-reviewer`). Offload duplicates, complexity, and `L1`–`L4` dead-code/unused-dep scans to project-native tools + `b3 guard mechanical-check`/`symbol-check` first per [`../../../../workflows/references/static-analysis.md`](../../../../workflows/references/static-analysis.md). Ask:
- *“Given the final implementation and current requirements, is all of this code still necessary?”*
- *“Could the same requirements be satisfied with substantially less implementation and maintenance complexity?”*

## Implementation residue (risk-based)

- Duplicated business logic, duplicate conditions, or equivalent/redundant branches
- Unreachable paths, obsolete fallback behavior, or stale compatibility shims
- Dead feature flags, leftover migration logic, or temporary workarounds turned permanent
- Redundant state, redundant derived state, unnecessary React effects, or duplicate subscriptions
- Duplicate mappings/transforms, validation, or error handling
- Pass-through wrappers or abstractions whose original consumer disappeared
- Obsolete overloads, stale DTO/model fields, duplicated API contracts, or obsolete cache layers
- Defensive guards for states proven impossible or irrelevant by current contracts
- Comments describing removed behavior, completed TODOs, or obsolete tests for removed behavior
- Old code paths retained after a replacement became canonical

## Disproportionate complexity (overengineering)

- Custom parsers when simpler supported alternatives (e.g., plain Markdown/config or built-in parsers) exist
- Excessive validation or schema machinery for low-risk convenience features
- New frameworks, engines, or reusable subsystems introduced without a concrete requirement
- Reimplementation of standard library or native platform functionality
- Unnecessary configuration layers or indirection for simple options
- Disproportionate code and maintenance cost relative to feature value

## Classification

| Class | Meaning | Action |
| --- | --- | --- |
| **CONFIRMED** (`CONFIRMED REDUNDANCY` / evidenced `CONFIRMED` overengineering) | Repo evidence proves no remaining responsibility, full duplication, or a concrete simpler alternative that meets ALL security, correctness, portability, compatibility, and verified performance requirements (never LOC alone) | Map to `simplification` + `CONFIRMED`; require minimal cleanup |
| **SPECULATIVE** (`LIKELY REDUNDANT`) | Strong signal, but a dependency, requirement, or simpler alternative remains unproven | Keep `SPECULATIVE` / non-blocking; do not delete without proof |
| **INTENTIONAL COMPLEXITY** | Concrete requirement holds (security, correctness, portability, compatibility, explicit spec, verified perf, external consumer) | Accept / preserve; do not flag or simplify away |
| **UNKNOWN** | Insufficient evidence to judge safety | Do not convert uncertainty into deletion |

Require a concrete simpler alternative meeting ALL security, correctness, portability, compatibility, and verified performance requirements—and **production-consumer verification** (`unit tests != runtime/production caller`, checking runtime entrypoints separately from tests) for unused/orphan symbols—before classifying overengineering or dead code as `CONFIRMED`. Never flag complexity on line count alone, never turn stylistic preferences into blocking findings, and never perform aesthetic line-count golf or unrelated refactors.
