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
| Skill / Rule / Workflow | Executable method or constraint | `.cursor/skills/`, `rules/`, `workflows/` |
| Implementation | Change in a product (or in this system) | the target repo |
| Verification | Evidence | verification skill / rule |
| Review | Independent check; loop when implemented | `review-loop/spec.md` |
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

- Personal preference (stays in `profiles/` or `knowledge/personal/`)
- Project-only or employer convention
- Host-specific tricks (adapter residue, not core)
- Unverified volatile claims
- One-off incident response dressed as a universal constraint

## Maturity

| Layer | Status |
| --- | --- |
| Research and domain synthesis | **Present** |
| Review-loop spec and orchestrator procedure | **Present** — [`../review-loop/spec.md`](../review-loop/spec.md), [`../review-loop/strategy.md`](../review-loop/strategy.md), [`.cursor/commands/review-loop.md`](../.cursor/commands/review-loop.md). Agent procedure, not a host plugin. Default inner-loop cap is 5 (`strategy.md`). |
| Review-loop on a real product PR / host subagent isolation | **NOT VERIFIED** — tabletop only: [`../research/validation/review-loop-results.md`](../research/validation/review-loop-results.md) |
| Knowledge after lessons | **Minimal** — [`../knowledge/personal/engineering-context.md`](../knowledge/personal/engineering-context.md); no `stable/` or `volatile/` yet |

Do not skip Research → Synthesis when adding more skills. Do not tell agents the review loop is unspecified: the procedure exists; product-repo exercise and host isolation are unverified.
