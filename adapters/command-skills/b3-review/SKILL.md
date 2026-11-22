---
name: b3-review
description: >
  One evidence-based code-review pass on the current change. Use when the
  user says review this diff, $b3-review, or /b3-review. Not the full independent
  review loop ($b3-review-loop).
---

# b3-review

**Action now:** one evidence-based review pass on the current diff/PR (not the multi-iteration `/b3-review-loop`).

Resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, or this repo) and open `{B3_HOME}/skills/engineering/code-review/SKILL.md` directly (plus smallest domain skill such as `api-security`, `accessibility`, `react-performance`, `ef-core`, or `threejs-performance` only when matched):
- **Local diff/branch (default):** scope with `{B3_HOME}/scripts/b3-guard.{ps1,sh} diff-scope` + `mechanical-check` (+ `symbol-check` on refactors/deletions).
- **GitHub PR (`#<id>` / URL) or optional PR comment/review:** also open `{B3_HOME}/skills/engineering/code-review/references/github-pr-review.md` (external write gate: post only when requested/confirmed).
