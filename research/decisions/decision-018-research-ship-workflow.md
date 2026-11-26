# Decision 018 — Portable `/b3-research-ship` Research-First Delivery Workflow

> **Status:** Amended (`CF-01`, `CF-09`, `CF-12`): GitHub-specific branch-protection, ruleset, repository permission-tier, and approval-count enforcement is decoupled from `b3-guard merge-policy-check` Core into native hosting-provider enforcement plus optional thin `scripts/b3-github-verify.{ps1,sh}` (`mode=local|github`, degrading to `PROVIDER_UNAVAILABLE` exit `2` when `gh`/auth/network is unreachable); pilot validation notes relocated from `docs/research-ship-tuvi-pilot.md` to sanitized provenance in [../validation/research-ship-pilot-notes.md](../validation/research-ship-pilot-notes.md).

## Context

`/b3-ship` (`workflows/ship.md`) optimizes implementation delivery from an engineering plan or feature requirement, but research-intensive engineering (classical/domain source discovery, multi-school contradiction analysis, independent source verification separate from unit tests, formalization readiness, dual technical + editorial gates, governed PR merge eligibility, and post-merge ancestry verification) requires explicit research-first stages without bloating `/b3-ship` or `AGENTS.md` always-on context.

An audit of `b3_ai-engineering` alongside the reference pilot `hptbee/b3_tuvi` (`docs/tuvi/INTERPRETATION_EDITORIAL_POLICY.md`, `RELEASE_GOVERNANCE_V2.md`, `MASTER_ROADMAP.md`, `CURRENT_STATUS.md`, `ANTIGRAVITY_AGENT_WORKFLOW.md`, `THREE_ANTI_KNOWLEDGE_ACTIVATION.md`) showed that most execution mechanics already existed (`b3-guard` waves/worktree/diff/mechanical/symbol/verify/precommit, `ship.md`, `review-loop/strategy.md`, 4-host `adapters/`, `measure-context`).

## Options considered

1. **Duplicate `/b3-ship` into a parallel standalone engine** (`research-ship-guard`, separate `agents/`, inline domain rules). Rejected: doubles maintenance, blows the `8500 B` `agents/*.md` budget (`8478 B` baseline), and violates `rules/portability.md`.
2. **Extend shared `b3-guard` primitives + add a compact progressive-disclosure workflow (`workflows/research-ship.md`) and portable product profile contract (`.b3/research-policy.json` + `.b3/research-profile.md`)**.

## Decision

**ADOPT option 2.**

- **Shared `b3-guard.{ps1,sh}` extensions (PS + Bash parity):**
  - `-Namespace` (`ship` [default] | `research-ship`) across `new-run`, `resolve-run`, `list-runs`, `prune`, keeping `.b3/research-ship/` checkpoints isolated from `.b3/ship/` and excluded from git diffs/precommits.
  - `evidence-check` (`b3-evidence-v1` SHA-256 source manifests with strict repo-containment and `EVIDENCE_FRESH`/`STALE`/`MISSING` exit codes `0`/`2`/`1`).
  - `merge-policy-check` (fail-closed pre-merge gate defaulting to `auto_merge: disabled` → `PR_READY` `exit 2`, blocking unmet CI/review/governance/protected-paths `exit 1`, authorizing merge `exit 0` only when explicitly authorized, plus `-PostMerge` ancestry verification leaving `runtime_served`/`deployed` `NOT_VERIFIED`).
- **Reuse existing `agents/` (`8478 B` unchanged):** Do not add a 6th file under `agents/`. Phase E source verification reuses isolated read-only subagents with `b3-reviewer`-style compact output; Phase G/H reuses `workflows/ship.md`, `review-loop/strategy.md`, and `agents/b3-*.md`.
- **Domain decoupling:** Zero Tử Vi policy or terminology in portable core. Pilot integration notes live in [../validation/research-ship-pilot-notes.md](../validation/research-ship-pilot-notes.md) (relocated and sanitized from `docs/research-ship-tuvi-pilot.md`; `0` runtime LLM tokens) alongside product-local `.b3/research-policy.json` / `.b3/research-profile.md`.
- **Single-hop adapter discovery:** `commands/b3-research-ship.md` and `adapters/command-skills/b3-research-ship/SKILL.md` open `workflows/research-ship.md` directly; `install-product.{ps1,sh}` gitignores both `.b3/ship/` and `.b3/research-ship/`.

## Consequences

- `always_on_total` rises minimally by `+292 B` (`AGENTS.md` `+51 B` and `b3-research-ship/SKILL.md` frontmatter `+241 B`) to `15,414 B` (`~3,854 tok` on merged `origin/main`; `14,940 B` → `15,232 B` at initial proposal); existing 7 commands, `workflows/ship.md` (`9,460 B`), and `agents/*.md` (`8,478 B`) stay unmodified by this feature.
- Deterministic source freshness, governance fail-closed merge checks, and `.b3/research-ship/` isolation are verifiable offline across PowerShell and Git Bash (`scripts/validate-research-ship.ps1`).
- Live multi-host slash-command UX and live GitHub branch-protection/auto-merge execution against real PRs remain `UNKNOWN / INCOMPLETE` until exercised in live host sessions.
