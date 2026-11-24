# Decision 015 — Evidence-backed quality gates, safety tripwires, symbol ledger, and dynamic context/routing

## Context

An architectural and external-ecosystem audit against 8 public agent harnesses (`apokamo/kaji`, `open-gsd/gsd-core`, `Ralph-Workflow/Ralph-Workflow`, `umputun/ralphex`, `github/spec-kit`, `bmad-code-org/BMAD-METHOD`, `ruvnet/ruflo`, `Geodesiasur/everything-claude-code`) confirmed that B3's core lifecycle was lean on static context (`14,940 B` always-on) but lacked:
1. Cryptographically/Git-bound verification evidence (`b3-verify-v1` receipt tied to `HEAD` and working-tree content hash).
2. Deterministic safety tripwires for secrets, destructive SQL on non-test/non-doc paths, mass deletion, and mid-operation Git states.
3. Lightweight symbol-ledger checks for dangling references and orphan internal code after refactors.
4. Read-write overlap and worktree-base/common-dir validation on parallel waves, plus legacy `.b3/autodev/` checkpoint fallback.
5. Portable 4-tier escalation and explicit Context Packet framing without inflating always-on token budgets.

## External sources inspected & dispositions

| Source | Relevant files inspected | Disposition | Rationale & tradeoff |
| --- | --- | --- | --- |
| `apokamo/kaji` | `docs/adr/005-artifact-primary-verdict.md` | **ADAPT** (`verify-run` / `verify-check` `b3-verify-v1`) | Adopted file-backed structured evidence checked deterministically by `b3-guard`; rejected full YAML workflow runner to preserve B3 host neutrality. |
| `Ralph-Workflow/Ralph-Workflow` | `docs/ralph-workflow-policy/gate-script-policy.md`, `docs/agents/fabrication-guard.md`, `ralph-workflow/ralph/agents/invoke/_completion_evidence.py` | **ADAPT** (fail-closed exit contracts, strict mode, SHA/effect evidence) | Enforced fail-closed `precommit -RequireVerifyReceipt`, partial-staging rejection, and exit-code honesty; skipped fabrication-specific markdown scrapers already covered by B3 rules. |
| `open-gsd/gsd-core` | `gsd-core/references/context-budget.md`, `gsd-core/references/execute-phase-wave-guard.md`, `gsd-core/workflows/execute-phase/steps/worktree-base-check.md`, `gsd-core/references/worktree-path-safety.md` | **ADAPT** (`check-worktree`, `ExpectedBaseSha` wave degrade, scoped context packets, `review_delta_load` metric) | Adopted worktree root/common-dir & base-SHA checks plus auto-degrade to sequential; rejected JS runtime `gsd_run` helper and multi-config `.planning/config.json`. |
| `umputun/ralphex` | `docs/backlog/worktree-guard-refuses-mid-operation-checkout.md` | **ADAPT** (`Test-GitMidOperation` in `precommit`, `check-wave`, `check-worktree`) | Blocked commits, waves, and worktrees during `MERGE_HEAD`, `REBASE_HEAD`, `CHERRY_PICK_HEAD`, etc.; kept linked worktrees allowed via `--git-common-dir`. |
| `github/spec-kit` | `src/specify_cli/workflows/step/gate/__init__.py`, `templates/checklist-template.md` | **ADAPT** (AC-to-check readiness check in `planning`) | Added crisp readiness check in `skills/engineering/planning/SKILL.md`; rejected heavy Python workflow engine and multi-file spec directories by default. |
| `bmad-code-org/BMAD-METHOD` | `skills/method/bmad-architecture/references/reviewer-gate.md`, `skills/method/bmad-retrospective/scripts/git_evidence.py` | **ADAPT** (deterministic CLI audit before semantic review, clean JSON/line exit contracts) | Kept `0`-token `mechanical-check` + `symbol-check` ahead of LLM review and read-only subagent outputs; rejected heavyweight agile ceremony/role explosion. |
| `ruvnet/ruflo` & `everything-claude-code` | `.claude-plugin/hooks/`, `.cursor/hooks/` | **DEFER / REJECT** for core | Vector DB hooks, MCP daemons, and host-specific JS hook adapters violate host-neutral zero-runtime-daemon simplicity (`rules/portability.md`). |
| Internal shift-left patterns | Invariant bug-class sweep, Symbol Ledger, Failure/Write-path Matrix | **ADAPT** (risk-gated in `ship-templates.md`, `b3-guard symbol-check`) | Kept `failure_matrix`, `write_paths`, and `io_budget` conditional on `depth: detailed` risk triggers so small edits stay zero-ceremony. |

## Decision

**ADOPT** the deterministic CLI extensions (`verify-run`, `verify-check`, `symbol-check`, `check-worktree`, `mechanical-check safety_hits`, `check-wave -WaveReads/-ExpectedBaseSha`, hardened `precommit`, and `.b3/autodev/` legacy fallback) in `scripts/b3-guard.{ps1,sh}`, along with risk-adaptive matrix prompts, stable-prefix Context Packets, AC-to-check readiness checks, and portable 4-tier escalation in canonical docs.

## Consequences & tradeoffs

- **Zero always-on bloat:** `always_on_total` remains identical (`14,940 B`), while all new structural safety checks execute with `0` LLM tokens.
- **Working-tree vs index receipt design:** `Get-TreeFingerprint` hashes `HEAD` + `RelevantPaths` + working-tree file blobs (`W`) so `git add` right before commit does not invalidate a working-tree test run, while `precommit -RequireVerifyReceipt` separately fails closed on `staged != WT` or out-of-receipt-scope staged paths.
- **Lightweight symbol heuristics:** `symbol-check` uses single-line ERE/regex patterns (zero compiler/AST dependencies) and conservatively skips exported symbols in `orphan_internal` so public APIs never cause false findings; multiline signatures or dynamic metaprogramming remain outside scope.
- **Limitation:** Cross-host live agent slash-command UX (Cursor/Claude/Codex/Antigravity) remains unverified in automated CLI tests.
