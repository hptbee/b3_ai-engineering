# Decision 012 — Autodev v2 hardening and progressive disclosure

## Context

`workflows/autonomous-development.md` grew to 464 lines and had two internal issues alongside several workflow ergonomics gaps:

1. **Internal drift and gaps:** Product repos changed to ignore `.b3/autodev/` instead of `.b3/` so `.b3/home` can commit (`38e0f45`), while the workflow still mandated ignoring `.b3/`; pre-existing dirty files were permitted on entry yet swept into task `git diff` / final dirty-tree checks; and there was no pre-`T001` baseline probe of canonical repo checks.
2. **External pattern evaluation:** Community `/leader` (`ccc-skills`) planning and task-decomposition notes (reviewed 2026-11-21) surfaced useful shift-left controls (baseline CI/hook probes, explicit `REUSE` / `OBSOLETES`, numbered acceptance criteria, invariants, conditional data/IO risk checks, owned vs read-only files, upfront sizing warning) mixed with heavy multi-agent debate and broad stop gates.

## Options considered

1. Import `/leader` multi-matrix Concept Pack, 3-lens Debate Round, parallel wave execution, and high-risk pause gates verbatim.
2. **ADAPT** the high-signal shift-left invariants and deterministic Git/fingerprint checks into B3's single-orchestrator workflow, split templates and resume details via progressive disclosure, and **REJECT** debate/stop-gate bloat.

## Decision

**ADOPT option 2.**

### ADAPT

- **Pre-flight baseline & dirty-tree isolation:** Record `initial_dirty_paths` and discover repo-native `build`/`typecheck`/`lint`/`test` commands (CI/hooks/manifests) to record `baseline_status` at `run_base_sha`, separating pre-existing failures and unrelated edits from `T00N`. Align checkpoint ignore rule with `.b3/autodev/`.
- **Plan structure (`master-plan.md`):** Add `Invariants` (3–5 cross-task invariants), numbered `AC1..ACn` criteria, **Contract-first + single-task shared-hotspot ownership** (commit foundational types/configs once before dependent tasks read them from disk), and an upfront `review-loop/sizing.md` split warning (`> ~800 lines` or `>= 2 independent areas`).
- **Shift-left JIT `Analyze`:** Require `reuse:` and `obsoletes:` and separate `files` (owned/writable) from `read_only_deps` inside `watched_paths`.
- **Conditional `detailed` risk checks:** Require `write_paths` (multi-store writes + cache invalidation), `io_budget` (query/list/hot-render), and stateful/race/auth `edge_cases` only when the task touches those surfaces.
- **1-pass pre-code risk review:** On `depth: detailed`, run `architecture-reviewer` (`design-only`), plus `security-reviewer` (`design-only`) when auth/untrusted input/race/abuse applies — single pass, orchestrator adjudicates.
- **Risk-tiered post-code review:** Small `inline` tasks without auth/contract/schema/hot-path surface take 1 independent `reviewer` pass (escalating to `review-loop` only on a blocking `CONFIRMED` finding); `notes`/`detailed` and `Final verification` run full `review-loop`.
- **Context isolation & safety snapshot:** Optional subagent-per-task `Implement + Test` for `>= 3`-task `notes`/`detailed` runs; record `pre_fix_object` via `git stash create` (falling back to `HEAD` when tracked files are clean) before entering `Fix`.
- **Deterministic guard helper & progressive disclosure:** Add `scripts/autodev-guard.{ps1,sh}` (`fingerprint`, `check-freshness`, `precommit`, `snapshot`) and extract `workflows/references/{autodev-resume.md,autodev-templates.md}` so `workflows/autonomous-development.md` stays concise (`<= 280` lines).

### REJECT

- Custom advisory lint rules overriding product repo linter config (`docs/precedence.md`).
- Hardcoding `QB-1..QB-7` boilerplate into every plan (`rules/` + `review-loop/spec.md` already carry quality bars).
- Mandatory 4-matrix Concept Pack on `inline` / `notes` tasks.
- Multi-round 3-lens Debate Round and broad stop-for-approval gates on `>= 4 tasks` or ordinary `auth`/`migration`/`shared` code ([`../rejected/reject-mandatory-debate-and-broad-autodev-gates.md`](../rejected/reject-mandatory-debate-and-broad-autodev-gates.md)).

### DEFER

- Parallel multi-WP wave execution on a shared working tree (keep sequential task commits as portable default across hosts without worktree orchestration).

## Consequences

- `workflows/autonomous-development.md` shrinks below 280 lines while gaining deterministic guard checks and pre-flight hygiene.
- `scripts/autodev-guard.{ps1,sh}` remains a pure CLI helper; the active session remains the single orchestrator (`decision-010`).
- Live multi-task product-repo `/autodev` execution remains `UNKNOWN / INCOMPLETE` until exercised in a real session (`autodev-v3`).

## Confidence

High on architecture alignment and Git/script invariants (verified by behavioral tests); runtime agent compliance across hosts remains `UNKNOWN / INCOMPLETE` until live product runs.
