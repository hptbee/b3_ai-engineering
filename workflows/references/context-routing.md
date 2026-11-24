# Context routing (on-demand)

On-demand routing (`0 B` always-on). Load <=1x/phase only when triggered (optional MCPs active, cross-file symbol/impact nav, or multi-iter cache reuse); skip on native-only / direct-known diffs. Never paste to subagents; pass 1L `context_hint:`.

## Detection & 4 MCP states
Detect active host tools once/phase; never assume MCP exists, repeat absent probes, or mutate host/IDE/MCP configs.
- `both`: fresh `codebase-memory` (arch/impact) + `serena` (symbols/edits).
- `codebase-memory` only: fresh graph (arch/impact); native + `symbol-check` (symbols/edits).
- `serena` only: `serena` (symbols/callers/edits); native Git + `b3-guard` (arch/diff/grep).
- `neither`: native Git, direct read/edit, `b3-guard` only (zero MCP probing).

## Routing matrix (1 primary per need)
| Need | Primary | Fallback |
| --- | --- | --- |
| Arch/deps/cross-file impact | `codebase-memory` (fresh) | `serena` refs -> native (`git grep`, `symbol-check`, read) |
| Symbol inspect/nav/edit | `serena` (active) | native read/edit + `b3-guard symbol-check` |
| Known targets (**direct-known short-circuit**) | native read (`serena` surgical edit) | skip graph scan & probing |
| Diff/Git/mechanical & verify | `b3-guard` + native Git (`0 LLM tokens`) | n/a |

## Staleness, disclosure & reuse
- **Staleness:** commit-indexed `codebase-memory` is stale on `HEAD != graph_index_sha` (incl. reset/amend/branch-switch), uncommitted/untracked edits on watched/anchor/delta paths, or mismatched caller `graph_index_sha` (fails closed `graph_index_mismatch` until re-recorded) -> untrusted; fallback unless refreshed. Live LSP `serena` reads working tree (dirty-tree eligible).
- **Disclosure:** bounded slices, symbol bodies, or summaries only; never dump repos, raw graphs, or full files. Subagent `context_hint: tools=<both|codebase-memory|serena|native> cache=<ref|none> delta=<files|none>`.
- **Cache:** optional `b3-guard.{ps1,sh} context-cache` (`record|check`, `b3-context-v1`, strictly under `.b3/{ship,research-ship}/`) keyed on immutable `anchor_paths` (`read_only_deps`+`contract_files`) + SHA-256 `summary_ref` + optional `graph_index_sha`; mutable edits use `diff-scope -PrevSha` (`delta_files`). Invalidate (`CONTEXT_STALE`) on anchor/contract/summary/`HEAD`/graph-index drift.

## Review Loop, Research Ship & failure
- **Review Loop Iter 1 (diff-first):** `b3-guard diff-scope` + diff read; escalate only to targeted `serena` (callers) or `codebase-memory` (impact only for multi-file/contract/HIGH+).
- **Review Loop Iter 2+ (delta-first):** `delta_files` + affected callers + `OPEN` findings + changed contracts; reuse valid `anchor_paths` cache; skip repo reload & repeat graph scans. Keep fresh independent reviewers, circuit breakers, quality gates, `verify-check`/`review-ledger`.
- **Research Ship:** codebase exploration/impl (`repo-evidence`) only; never substitute MCP for verified domain sources (`evidence-check`), primary/secondary provenance, editorial review, or release authorization.
- **Graceful failure:** MCP error/timeout/stale index -> immediate native fallback; log degradation concisely, keep verify/review mandatory, never false `PASS`.
