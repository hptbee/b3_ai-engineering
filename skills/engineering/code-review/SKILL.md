---
name: code-review
description: >
  Use for one evidence-based review pass on a diff, PR, or recent change
  (architecture, correctness, security, perf, residue, tests). Not for
  implementing features, full review-loop, or rubber-stamp LGTM.
---

# Code review

Produce one honest review pass on a defined change. Iterative loops live in `review-loop/strategy.md` (`review-loop/spec.md`).

## When to use / not use

- **Use:** reviewing a PR, diff, or recent edits with separate severity, confidence, and finding lifecycle status.
- **Do not use:** implementing features (`problem-solving`), researching external playbooks (`research-engineering-patterns`), declaring a multi-iteration loop done without `review-loop/strategy.md`, or specialist deep dives (`security-reviewer`, `architecture-reviewer`, hot-path `performance-reviewer`).

Near miss: “write tests for this PR” → implementation + verification. “Is this safe to ship?” → this skill + executed verification evidence.

## Procedure

1. **Scope** — establish in/out target; empty or wrong target → `UNKNOWN / INCOMPLETE`.
2. **Understand** — read the diff and surrounding contracts; restate intent without inventing requirements.
3. **Review** — examine scoped dimensions from `review-loop/spec.md` (skip only with a recorded reason):
   - **Performance (every pass, light):** classify as **CONFIRMED** (measured/reproduced), **EVIDENCED RISK** (known hot-path defect in diff, e.g. unbounded query, `useFrame`+`setState`, sync CPU on request), or **SPECULATIVE** (non-blocking). Load the smallest stack perf skill if matched; route `agents/performance-reviewer.md` only on hot-path diffs.
   - **Simplification / implementation residue (every pass):** ask *“Given the final implementation and current requirements, is all of this code still necessary?”* Look for change residue from earlier iterations/fixes using [`references/residue-checklist.md`](references/residue-checklist.md). Only **CONFIRMED REDUNDANCY** becomes a cleanup finding; leave `LIKELY REDUNDANT` / `UNKNOWN` non-blocking and accept `INTENTIONAL COMPLEXITY`. Never refactor unrelated code.
4. **Record findings** — use `review-loop/spec.md` schema (`id`, `severity`, `confidence`, `status`, `category`, `location`, `description`, `evidence`, `verification`). Promote to `CONFIRMED` only with concrete evidence.
5. **Consolidate** — merge duplicates; separate blockers from nits; output compactly without echoing full code blocks.
6. **Tie to verification** — name checks/probes; never claim they passed unless executed (`verification` skill).

## Progressive disclosure

- Residue taxonomy & classification: [`references/residue-checklist.md`](references/residue-checklist.md)
- Finding schema, lifecycle & false convergence: `review-loop/spec.md`
- Isolated roles: `agents/{reviewer,security-reviewer,architecture-reviewer,performance-reviewer,fixer}.md`
- Hard rules: `rules/evidence-and-provenance.md`, `rules/verification.md`

## Verification & failure handling

- Complete only when scoped dimensions were examined or marked incomplete; tool failure → `UNKNOWN / INCOMPLETE`.
- Diff too large → sample by risk and state what was not reviewed; missing tests → mark verification incomplete; zero findings → still list what was checked.
