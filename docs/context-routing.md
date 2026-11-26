# MCP-Aware Context Routing

Human-facing guide (`0 B` runtime tokens — never loaded by `AGENTS.md`, `rules/*.md`, or workflows).

## Architecture & Single-Source Contract

- **Canonical runtime contract:** [`workflows/references/context-routing.md`](../workflows/references/context-routing.md) (`<= 3000 B` LF cap), loaded **on demand** at most once per phase across the 6 scoped workflows (`/b3-ship`, `/b3-research-ship`, `/b3-review`, `/b3-review-loop`, `/b3-debug`, and `/b3-implement` / `feature-implementation`) **only when triggered** (optional MCPs active, cross-file symbol/impact navigation, or multi-iter `context-cache` reuse) and skipped on native-only / direct-known diffs.
- **Zero always-on overhead:** `AGENTS.md` and `rules/*.md` do not load or reference context routing or MCP servers (`+0 B` MCP routing tax).
- **Hint-only subagents:** Orchestrators never paste `context-routing.md` into subagents. `agents/b3-reviewer.md` and `agents/b3-fixer.md` consume only a 1-line `context_hint: tools=<both|codebase-memory|serena|native> cache=<ref|none> delta=<files|none>` and explicitly never reload `context-routing.md`.
- **Bounded disclosure & short-circuit:** Prefer bounded slices, symbol bodies, and compact summaries — never dump entire repositories, raw graphs, or full files. When target files/symbols are already known (**direct-known short-circuit**), read directly (or apply surgical `serena` edit) and skip graph scans and absent-MCP probing.

## Capability Matrix (4 MCP States & 1 Primary Tool per Need)

Detect active host tools at most once per phase; never assume MCP servers exist, repeat probes for absent tools, or mutate host/IDE/MCP configs.

### Four Availability Combinations

| Active MCP State | Architecture / Impact | Symbol Inspect / Nav / Edit | Diff / Mechanical / Verify |
| --- | --- | --- | --- |
| `both` | Fresh `codebase-memory` | `serena` (live workspace LSP) | `b3-guard` + native Git (`0 LLM tokens`) |
| `codebase-memory` only | Fresh `codebase-memory` | Native read/edit + `b3-guard symbol-check` | `b3-guard` + native Git (`0 LLM tokens`) |
| `serena` only | `serena` refs + native Git/`b3-guard` | `serena` (live workspace LSP) | `b3-guard` + native Git (`0 LLM tokens`) |
| `neither` (native) | Native Git (`git grep`), direct read, `b3-guard` | Native read/edit + `b3-guard symbol-check` | `b3-guard` + native Git (`0 LLM tokens`) |

### One Primary Tool per Need & Graceful Failure

| Need | Primary | Fallback |
| --- | --- | --- |
| Architecture, deps, cross-file impact | `codebase-memory` (only when fresh) | `serena` refs -> native (`git grep`, `symbol-check`, direct read) |
| Symbol inspection, callers, surgical edits | `serena` (when active) | Native direct read/edit + `b3-guard symbol-check` |
| Known target files/symbols (**direct-known short-circuit**) | Native direct read (`serena` surgical edit if active) | Skip graph scan and MCP probing |
| Diffs, Git state, mechanical checks, verification | `b3-guard.{ps1,sh}` + native Git (`0 LLM tokens`) | n/a |

**Graceful failure:** Any MCP timeout, error, or stale index triggers immediate native fallback. Log degradation concisely, keep `b3-guard verify-check` and independent review mandatory, and **never** emit a false `PASS` or clean verdict from MCP silence.

## Commit-Indexed Graph vs Live-Workspace LSP Staleness

- **`codebase-memory` (commit-indexed graph):** Untrusted (`graph_index=STALE`) whenever `HEAD != graph_index_sha` (including reset, amend, or branch switch), uncommitted/untracked/staged/submodule edits touch watched, anchor, or scoped paths, or a caller-supplied `graph_index_sha` mismatches the recorded cache value. Fall back to `serena` or native tools unless the index is refreshed.
- **`graph_index_sha` integrity invariant (P1):** During `b3-guard context-cache -Action check`, caller-supplied `-GraphIndexSha` / `--graph-index-sha` **never overrides** the recorded `graph_index_sha` in the cache file. Any mismatch against the recorded value (including switching between `none` and a SHA or supplying a different SHA) fails closed with `CONTEXT_STALE` (`exit 2`, reason `graph_index_mismatch`, `graph_index=STALE`, `live_lsp_eligible=true`) until the cache is validly re-recorded via `-Action record`.
- **`serena` (live-workspace LSP):** Reads the live working tree directly, so it remains dirty-tree eligible (`live_lsp_eligible=true`) even when `graph_index=STALE`.

## Review Loop Reuse & `b3-guard context-cache`

- **Conditional contract loading (P2):** In [`review-loop/strategy.md`](../review-loop/strategy.md) and [`review-loop/hierarchical.md`](../review-loop/hierarchical.md), the orchestrator loads `workflows/references/context-routing.md` (`<=1x/loop`) **only when triggered** (optional MCPs active in host, cross-file symbol/impact lookup beyond the diff, or multi-iteration / multi-unit `context-cache` reuse). On direct-known, native-only, or single-pass diffs (and native direct-known hierarchical units), loading `context-routing.md` is **skipped** (default `context_hint: tools=native cache=none`), yielding zero extra routing-contract load (`0 B`) on those runs.
- **Iteration 1 (diff-first):** Run `b3-guard diff-scope` + `mechanical-check` (+ `symbol-check` on refactors) and inspect the diff first (direct-known short-circuit; skip graph scans and `context-routing.md` when native diff suffices); escalate only to targeted `serena` callers or `codebase-memory` impact (for multi-file/contract/`HIGH+` risk). Optionally record immutable anchors with `b3-guard.{ps1,sh} context-cache -Action record` (in hierarchical Level 2 units, bind `contract_files`/`read_only_deps` via `anchor_paths` and bind recorded Level 1 invariants via SHA-256 `summary_ref`).
- **Iteration 2+ (delta-first):** Pass `b3-guard diff-scope -PrevSha <snapshot>` (`delta_files`), affected callers, `OPEN` findings, and changed contracts. Validate cached immutable anchors via `b3-guard.{ps1,sh} context-cache -Action check`; when `CONTEXT_FRESH` (`exit 0`), reuse cached summaries and skip full repo reload or repeat graph scans while keeping fresh independent reviewers, circuit breakers, quality gates, `verify-check`, and `review-ledger` intact.
- **Deterministic cache contract (`b3-context-v1`):**
  - Strictly contained under `.b3/{ship,research-ship}/` (rejects generic `.b3/` files, `.git`, symlinks/junctions, ADS `:`, globs, pathspec magic, trailing dots/spaces, control characters, mid-operation Git state, and secret paths).
  - Keys on immutable `anchor_paths` (`read_only_deps` + `contract_files` tree fingerprint), SHA-256 `summary_ref`, `scope_id`, `head_sha` forward ancestry, and optional `graph_index_sha`.
  - Mutable Fixer edits outside `anchor_paths` (uncommitted or forward-committed) stay `CONTEXT_FRESH` (`exit 0`) when `graph_index_sha=none`, while `diff-scope -PrevSha` isolates `delta_files`.
  - Fails closed with `CONTEXT_STALE` (`exit 2`) on changed anchors/contracts (`anchor_changed`), changed `summary_ref` digest (`summary_changed`), diverged `HEAD` (`head_diverged`), changed anchor set (`anchor_scope_changed`), mismatched caller `graph_index_sha` (`graph_index_mismatch`), or stale graph index (`graph_index_stale`, with `live_lsp_eligible=true`), and `CONTEXT_CORRUPT` / `CONTEXT_MISMATCH` / `CONTEXT_ERROR` (`exit 1`) on tamper or cross-scope mismatch.

## Research Ship Boundary (`repo-evidence` Only)

In [`workflows/research-ship.md`](../workflows/research-ship.md) and [`workflows/references/research-ship-gates.md`](../workflows/references/research-ship-gates.md), optional codebase MCP output (`codebase-memory` / `serena`) is strictly classified as **`repo-evidence`** for repository exploration and Phase G implementation. It must **never** substitute for verified domain sources (`b3-guard evidence-check`), primary/secondary provenance, the **Research Gate**, or **Editorial / Authority** release governance.

## 4-Host Compatibility

| Host | Canonical Consumption | MCP & Config Handling |
| --- | --- | --- |
| **Cursor** | `.cursor/rules/*.mdc` + `adapters/sync-skills.{ps1,sh} cursor` | Detects active host MCP tools once/phase; never edits Cursor MCP config. |
| **Antigravity** | `AGENTS.md` + `.agents/skills.json` / plugin (`sync-skills antigravity`) | Detects active host MCP tools once/phase; never edits `~/.gemini` config. |
| **Codex** | `AGENTS.md` + `adapters/sync-skills.{ps1,sh} codex` | Detects active host MCP tools once/phase; never edits `~/.codex/config.toml`. |
| **Claude Code** | `CLAUDE.md` (`@AGENTS.md`) + `adapters/sync-skills.{ps1,sh} claude` | Detects active host MCP tools once/phase; never edits `~/.claude/settings.json`. |

## Measured Static Context Overhead

Live exact LF byte counts, `(bytes + 2) / 4` token estimates, and strict cap checks are owned by [`scripts/measure-context.ps1`](../scripts/measure-context.ps1) / [`scripts/measure-context.sh`](../scripts/measure-context.sh) (`-Strict` / `--strict`):
- Enforce `0` warnings across static caps (`AGENTS.md <= 3600 B`, `SKILL.md <= 4000 B`, skill frontmatter `<= 280 B`, `workflows/ship.md <= 9500 B`, `workflows/research-ship.md <= 9500 B`, `workflows/references/context-routing.md <= 3000 B`, `workflows/references/dispatch-naming.md <= 9200 B`, `review-loop/strategy.md <= 5200 B`, `agents/b3-*.md <= 8500 B`).
- `AGENTS.md` and `rules/*.md` impose `+0 B` MCP routing tax (`context-routing.md` loads strictly on demand).

Validation: run `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate-context-routing.ps1` (PS + Git Bash parity across all 6 test groups).

## Not Verified / Known Limits (`UNKNOWN / INCOMPLETE`)

- **Live external MCP server execution:** Local CLI tests (`scripts/validate-context-routing.ps1`) validate deterministic `b3-guard context-cache`, `diff-scope`, contract hooks, and static budgets; they do **not** run live Codebase Memory or Serena MCP servers.
- **Live host IDE UI discovery:** Adapter checks verify local symlinks/junctions and `.agents/skills.json`, not live MCP tool registration or UI discovery inside Cursor, Antigravity, Codex, or Claude Code.
- **Runtime token / cost savings:** Actual runtime token, latency, and cost impact depend on host implementation, MCP server indexing, and repository workload; no synthetic or unmeasured runtime savings are claimed here.
