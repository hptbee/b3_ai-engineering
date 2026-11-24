# Context routing (on-demand)

On-demand (`0 B` always-on). Load <=1x/phase only when triggered (active MCPs, cross-file symbol/impact, or cache reuse); skip on native-only / direct-known diffs. Pass 1L `context_hint:` to subagents (never paste this doc).

## Detection & 4 MCP states
Detect active host tools once/phase; never assume MCPs, re-probe absent tools, or mutate configs.
- `both`: fresh `codebase-memory` (arch/impact) + `serena` (symbols/edits).
- `codebase-memory` only: fresh graph (arch/impact); native + `symbol-check` (symbols/edits).
- `serena` only: `serena` (symbols/callers/edits); native Git + `b3-guard` (arch/diff/grep).
- `neither`: native Git, direct read/edit, `b3-guard` only (zero probes).

## Routing matrix (1 primary per need)
| Need | Primary | Fallback |
| --- | --- | --- |
| Arch/deps/impact | `codebase-memory` (fresh) | `serena` refs -> native (`git grep`, `symbol-check`) |
| Symbol inspect/edit | `serena` (active) | native read/edit + `symbol-check` |
| Known targets (**direct-known short-circuit**) | native read (`serena` edit) | skip graph scan |
| Diff/Git/verify | `b3-guard` + native Git (`0 tok`) | n/a |

## Staleness, disclosure & reuse
- **Staleness:** commit-indexed `codebase-memory` is stale on `HEAD != graph_index_sha`, uncommitted/untracked edits on watched/anchor/delta paths, or `graph_index_mismatch` (fails closed) -> fallback unless refreshed. Live LSP `serena` reads working tree.
- **Disclosure:** bounded slices/symbols/summaries only; never dump repos or full files. `context_hint: tools=<both|codebase-memory|serena|native> cache=<ref|none> delta=<files|none>`.
- **Cache:** optional `b3-guard context-cache` (`record|check`, `b3-context-v1`, under `.b3/{ship,research-ship}/`) on immutable `anchor_paths` (`read_only_deps`+`contract_files`), SHA-256 `summary_ref`, opt `graph_index_sha`; mutable edits use `diff-scope -PrevSha` (`delta_files`). Drift -> `CONTEXT_STALE`.

## Review Loop, Research Ship & failure
- **Review Loop Iter 1 (diff-first):** `diff-scope` + diff; escalate only to targeted `serena` (callers) or `codebase-memory` (multi-file/HIGH+ impact).
- **Review Loop Iter 2+ (delta-first):** `delta_files` + callers + `OPEN` + changed contracts; reuse valid cache; no repo reload/graph repeat. Keep fresh reviewers, breakers, `verify-check`/`review-ledger`.
- **Research Ship:** codebase exploration/impl (`repo-evidence`) only; never substitute MCP for domain sources (`evidence-check`), provenance, editorial review, or release auth.
- **Graceful failure:** MCP error/timeout/stale -> native fallback; log concisely, keep verify/review mandatory, never false `PASS`.
