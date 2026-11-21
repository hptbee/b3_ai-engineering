# Simplification & implementation residue checklist

Reference for [`../SKILL.md`](../SKILL.md). Ask: *“Given the final implementation and current requirements, is all of this code still necessary?”*

## Target categories (risk-based)

- Duplicated business logic, duplicate conditions, or equivalent/redundant branches
- Unreachable paths, obsolete fallback behavior, or stale compatibility shims
- Dead feature flags, leftover migration logic, or temporary workarounds turned permanent
- Redundant state, redundant derived state, unnecessary React effects, or duplicate subscriptions
- Duplicate mappings/transforms, validation, or error handling
- Pass-through wrappers or abstractions whose original consumer disappeared
- Obsolete overloads, stale DTO/model fields, duplicated API contracts, or obsolete cache layers
- Defensive guards for states proven impossible by current contracts
- Comments describing removed behavior, completed TODOs, or obsolete tests for removed behavior
- Old code paths retained after a replacement became canonical

## Classification

| Class | Meaning | Action |
| --- | --- | --- |
| **CONFIRMED REDUNDANCY** | Repo evidence proves no remaining responsibility or full duplication | Map to `simplification` + `CONFIRMED`; require minimal cleanup |
| **LIKELY REDUNDANT** | Strong evidence, but one dependency/requirement remains uncertain | Keep `SPECULATIVE` / `INVESTIGATING`; do not delete without proof |
| **INTENTIONAL COMPLEXITY** | Named current responsibility holds (compatibility, security, perf, external consumer) | Accept; do not delete |
| **UNKNOWN** | Insufficient evidence to judge safety | Do not convert uncertainty into deletion |

Never perform aesthetic line-count golf or unrelated refactors.
