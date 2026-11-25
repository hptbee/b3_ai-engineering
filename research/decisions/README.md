# Research decisions

Recommendations from research evidence and post-synthesis architectural evolution. Historical ADRs are retained intact; supersessions and amendments are noted in-place.

Each record: ADOPT / ADAPT / REJECT / DEFER with rationale and consequences.

| Decision | Topic |
| --- | --- |
| [decision-001-skill-core.md](decision-001-skill-core.md) | SKILL.md core |
| [decision-002-portability.md](decision-002-portability.md) | Portable core + adapters |
| [decision-003-progressive-disclosure.md](decision-003-progressive-disclosure.md) | Three-tier disclosure |
| [decision-004-review-loop.md](decision-004-review-loop.md) | Review loop v1 |
| [decision-005-evaluation.md](decision-005-evaluation.md) | Eval phased investment |
| [decision-006-frontend-skills.md](decision-006-frontend-skills.md) | Frontend domain skills |
| [decision-007-backend-skills.md](decision-007-backend-skills.md) | Backend domain skills |
| [decision-008-skill-synthesis.md](decision-008-skill-synthesis.md) | Skill mining synthesis |
| [decision-009-cursor-native-layout.md](decision-009-cursor-native-layout.md) | Cursor-native layout (**superseded by 013**) |
| [decision-010-autonomous-development.md](decision-010-autonomous-development.md) | One lifecycle workflow, no external runner (**amended/superseded in naming & waves by `/b3-ship` + 012/013/014 + PR #31 4-mode waves**) |
| [decision-011-product-repo-attach.md](decision-011-product-repo-attach.md) | Thin B3 pointer in product repos; no skill copy |
| [decision-012-autodev-v2-hardening.md](decision-012-autodev-v2-hardening.md) | Autodev v2: progressive disclosure, shift-left residue/risk checks, tiered review, deterministic guard |
| [decision-013-host-neutral-multi-host-layout.md](decision-013-host-neutral-multi-host-layout.md) | Host-neutral canonical core + symmetric 4-host adapters (supersedes 009) |
| [decision-014-autodev-parallel-waves-and-mechanical-pass.md](decision-014-autodev-parallel-waves-and-mechanical-pass.md) | Parallel disjoint waves, `impl_agent` cache resume, CLI mechanical pass, bug-class sweep, 2-tier circuit breaker |
| [decision-015-evidence-gates-tripwires-and-context-budgets.md](decision-015-evidence-gates-tripwires-and-context-budgets.md) | Evidence-backed verification receipts, deterministic tripwires, symbol ledger, rw wave/worktree safety, and 4-tier routing |
| [decision-016-standalone-commands-quality-and-context.md](decision-016-standalone-commands-quality-and-context.md) | Hardened standalone command verification provenance, risk-adaptive planning/review, debug invariant sweeps, standalone review-loop state, and single-hop command loading |
| [decision-017-global-cursor-integration.md](decision-017-global-cursor-integration.md) | Machine-wide Cursor (`~/.cursor/`) and Antigravity (`~/.gemini/config/plugins/b3-ai-engineering/`) global installers, unified `adapters/install-global.{ps1,sh}` dispatcher, manifest verification, and coexistence rules |
| [decision-018-research-ship-workflow.md](decision-018-research-ship-workflow.md) | Portable `/b3-research-ship` workflow, `evidence-check`, provider-neutral `merge-policy-check` (**amended**: native provider rulesets/protection decoupled from `b3-guard` Core + optional thin `b3-github-verify`, sanitized pilot notes in [../validation/research-ship-pilot-notes.md](../validation/research-ship-pilot-notes.md)) |
