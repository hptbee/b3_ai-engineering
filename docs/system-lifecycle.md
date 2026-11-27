# System lifecycle

This repository is meant to evolve continuously. New skills, rules, and knowledge should arrive through a deliberate loop — not by copying the last incident into policy.

## Lifecycle

```text
Research
   ↓
Synthesis
   ↓
Knowledge
   ↓
Skill / Rule / Workflow
   ↓
Implementation
   ↓
Verification
   ↓
Review
   ↓
Lessons Learned
   ↓
Knowledge
```

| Stage | Meaning | Home |
| --- | --- | --- |
| Research | What externals say | `research/sources/` |
| Synthesis | Findings, comparisons, adopt/reject | `research/findings/`, `comparisons/`, `decisions/`, `rejected/` |
| Knowledge | Canonical reusable knowledge | `knowledge/` |
| Skill / Rule / Workflow | Executable method or constraint | `skills/`, `rules/`, `workflows/` |
| Implementation | Change in a product (or in this system) | the target repo |
| Verification | Evidence | verification skill / rule |
| Review | Independent check and iterative review loop | `review-loop/spec.md`, `review-loop/strategy.md` |
| Lessons learned | Candidates only | notes → then the promotion path below |

Research intake in more detail: [`../research/README.md`](../research/README.md) and [`research-methodology.md`](research-methodology.md).

The runtime feedback loop (rules constraining skills, verification feeding knowledge) is in [`architecture.md`](architecture.md). This file is about **how the system grows**.

## Lessons do not become rules automatically

A single bug, a single review, or a single project must not mint a permanent rule.

```text
Lesson
 ↓
Candidate Pattern
 ↓
Evaluation
 ↓
Human Approval
 ↓
Rule / Skill / Knowledge
```

| Gate | Ask |
| --- | --- |
| Lesson | What happened, with evidence? |
| Candidate pattern | Is this reusable, or was it local? |
| Evaluation | Does it still look sound across contexts? Would it false-positive? |
| Human approval | The owner accepts promotion. |
| Artifact | Rule (rare), skill, or knowledge entry — with provenance. |

Rejected candidates belong in `research/rejected/` (or a personal lesson labeled as not promoted). Do not delete the memory of why they were rejected.

## What not to promote

- Personal preference (stays in `knowledge/personal/`; `profiles/` is uncreated)
- Project-only or employer convention
- Host-specific tricks (adapter residue, not core)
- Unverified volatile claims
- One-off incident response dressed as a universal constraint

## Maturity (Single Canonical Table)

**Current status only.** Future priorities and phase acceptance criteria are owned by the [roadmap](roadmap.md), not this maturity table.

| Area | Status |
| --- | --- |
| Architecture, standards, precedence, lifecycle | **Present** (`docs/`) |
| Foundation rules + universal `AGENTS.md` + Claude `CLAUDE.md` bridge | **Present** (`rules/`, `AGENTS.md`, `CLAUDE.md`) |
| Skills (`24` canonical + `14` command-skills = `38` `SKILL.md`) | **Present** (`skills/`, `adapters/command-skills/`) |
| Commands (`14`) & Subagent roles (`5`) | **Present** (`commands/`, `agents/`, host-neutral canonical core) |
| Eval fixtures (`evals/`) | **Present** — schema validator active; automated LLM runner deferred |
| Review-loop orchestration (`/b3-review-loop`) | **Present** — [`../review-loop/strategy.md`](../review-loop/strategy.md), [`../review-loop/spec.md`](../review-loop/spec.md); product-repo exercise & host isolation **UNKNOWN / INCOMPLETE** ([`review-loop-results.md`](../research/validation/review-loop-results.md)) |
| Full lifecycles (`/b3-ship`, `/b3-research-ship`) | **Present** — [`../workflows/ship.md`](../workflows/ship.md), [`../workflows/research-ship.md`](../workflows/research-ship.md); live host slash UX **UNKNOWN / INCOMPLETE** |
| PR feedback lifecycle (`/b3-pr-resolve`, `/b3-pr-reply`, `/b3-pr-comment`) | **Present** — [`../skills/engineering/pr-feedback/SKILL.md`](../skills/engineering/pr-feedback/SKILL.md) + `b3 pr` |
| Knowledge after lessons | **Minimal** — [`../knowledge/personal/engineering-context.md`](../knowledge/personal/engineering-context.md); no `stable/` or `volatile/` yet |
| Profile files (`profiles/`) | **Not created** (`knowledge/personal/` holds background) |
| Host adapters (Cursor, Codex, Claude Code, Antigravity) | **Present** (`b3 sync`, `b3 install product`, `b3 install global`, Antigravity plugin); live IDE discovery **UNKNOWN / INCOMPLETE** |
| Standalone agent runtime / generic CLI runtime adapter | **Not implemented**; current orchestration is executed by the active coding-agent host. A public mock-based adapter contract is conditional roadmap work, not an existing integration. |
| Measured token/cost advantage over host baseline | **Not verified**; static context caps are measured, end-to-end billed usage and cost per verified task have no established benchmark. |

Do not skip Research → Synthesis when adding more skills. Do not tell agents the review loop is unspecified: the procedure exists; product-repo exercise and host isolation remain unverified.

## Anti-duplication and single-source ownership

One responsibility → one canonical owner → thin consumers:

| Concern | Canonical Owner | Rule for New Changes |
| --- | --- | --- |
| GitHub CLI exec & input validation | [`src/pr/gh_exec.rs`](../src/pr/gh_exec.rs) | Reuse shared helpers (`validate_repo_slug`, `validate_pr_number`, `resolve_gh_binary`, `parse_json_strict`) via native `b3 pr` (`src/pr/`) |
| Guard CLI (`verify-run/check`, `diff-scope`, `mechanical-check`, `merge-policy-check`) | [`src/guard/`](../src/guard/) | Route all guard checks through native `b3 guard`; keep verification, literal Git path handling, and merge-ledger gates in canonical Rust primitives |
| Host adapter file/link/manifest primitives | [`src/adapters/`](../src/adapters/) | Reuse canonical `resolve_b3_home`, `B3Manifest`, Win32 junction / Unix symlink helpers, and frontmatter utilities via `b3 sync` / `b3 install` |
| Behavioral test sandbox & fixture helpers | [`tests/`](../tests/) / [`tests/common/mod.rs`](../tests/common/mod.rs) | Reuse shared cached-seed test helpers; never inline duplicate `git init` or sync fixture copies |
| Workflow templates, resume & dispatch | `workflows/references/` | Workflows own step order; references own schemas, resume rules & wave dispatch contracts |
| Review & PR summary schema | [`review-template.md`](../skills/engineering/code-review/references/review-template.md) | Link to canonical summary format instead of redefining it in secondary templates |
| Static context budget counts | [`src/context.rs`](../src/context.rs) (`b3 context measure --strict`) | Run `--strict` instead of hardcoding volatile byte totals in docs |
