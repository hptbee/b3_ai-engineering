---
name: code-review
description: >
  Use for one evidence-based review pass on a diff, PR, or recent change
  (architecture, correctness, security, perf, residue, tests). Not for
  implementing features, full review-loop, or rubber-stamp LGTM.
---

# Code review

Produce one honest review pass on a defined change. Iterative orchestration lives in `review-loop/strategy.md` (do **not** load `review-loop/spec.md` on routine passes).

## When to use / not use

- **Use:** reviewing a PR, diff, or recent edits with separate severity, confidence, and evidence.
- **Do not use:** implementing features (`problem-solving`), external pattern mining (`research-engineering-patterns`), running a multi-iteration loop without `review-loop/strategy.md`, or specialist deep dives (`security-reviewer`, `architecture-reviewer`, hot-path `performance-reviewer`).

Near miss: “write tests for this PR” → implementation + verification. “Is this safe to ship?” → this skill + executed verification evidence.

## Procedure

1. **Scope** — establish in/out target (on Iteration 2+ with `delta_files`, inspect `delta_files` + affected boundary callers first); empty/wrong target → `UNKNOWN / INCOMPLETE`.
2. **Understand** — read scoped diff and surrounding contracts; restate intent without inventing requirements.
3. **Review** — check architecture, correctness, security, tests, maintainability, plus (skip any dimension only with a recorded reason):
   - **Performance (every pass, light):** classify as **CONFIRMED** (measured/reproduced), **EVIDENCED RISK** (known hot-path defect in diff: N+1, `useFrame`+`setState`, sync CPU on request), or **SPECULATIVE** (non-blocking). Load smallest stack perf skill only if matched; route `agents/performance-reviewer.md` on hot paths only.
   - **Simplification / residue (every pass):** ask *“Given the final implementation and current requirements, is all of this code still necessary?”* Open [`references/residue-checklist.md`](references/residue-checklist.md) only when classifying non-obvious residue. Only **CONFIRMED REDUNDANCY** is blocking; leave `LIKELY REDUNDANT` / `UNKNOWN` non-blocking and accept `INTENTIONAL COMPLEXITY`. Never refactor unrelated code.
4. **Record & consolidate** — use fields `id` (`R001`…), `severity` (`critical`/`high`/`medium`/`low`), `confidence` (`high`/`medium`/`low`), `status` (`CONFIRMED`/`SPECULATIVE`), `category` (`correctness`/`security`/`performance`/`architecture`/`simplification`/`maintainability`/`testing`/`reliability`/`ux`), `location`, `description`, `evidence`, `verification`. Require concrete evidence for `CONFIRMED`; merge duplicates; output compactly without echoing code blocks (if 0 findings, still list checked/skipped dimensions).
5. **Verification boundary** — name checks/probes; never claim they passed unless executed (`verification` skill). Tool failure → `UNKNOWN / INCOMPLETE`.
