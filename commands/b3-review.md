---
name: b3-review
description: One evidence-based code-review pass on the current change. Not the full independent review loop.
---

# b3-review

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, or this repo) and run one evidence-based review pass via `{B3_HOME}/skills/engineering/code-review/SKILL.md` (load smallest matching domain skill such as `api-security`, `accessibility`, `react-performance`, `ef-core`, or `threejs-performance` only when applicable):
- **Local diff/branch (default):** scope with `{B3_HOME}/scripts/b3-guard.{ps1,sh} diff-scope` + `mechanical-check` (+ `symbol-check` on refactors/deletions).
- **GitHub PR (`#<id>` / URL) or optional PR comment/review:** also open `{B3_HOME}/skills/engineering/code-review/references/github-pr-review.md` (external write gate: post only when requested/confirmed).
- **Consistent output template:** render both local and GitHub PR reviews with `{B3_HOME}/skills/engineering/code-review/references/review-template.md` (fixed severity `CRITICAL` | `HIGH` | `MEDIUM` | `LOW`).

Not the full iterative loop (`/b3-review-loop` → `{B3_HOME}/review-loop/strategy.md`; do **not** load `review-loop/spec.md` on routine passes).
