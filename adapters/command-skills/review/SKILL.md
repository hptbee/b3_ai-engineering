---
name: review
description: >
  One evidence-based code-review pass on the current change. Use when the
  user says review this diff, $review, or /review. Not the full independent
  review loop ($review-loop).
---

# review

**Action now:** one evidence-based review pass on the current diff/PR (not the multi-iteration `/review-loop`).

Resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, or this repo) and open `{B3_HOME}/skills/engineering/code-review/SKILL.md` directly (plus smallest domain skill such as `api-security`, `accessibility`, `react-performance`, `ef-core`, or `threejs-performance` only when matched):
- **Local diff/branch (default):** scope with `{B3_HOME}/scripts/b3-guard.{ps1,sh} diff-scope` + `mechanical-check`.
- **GitHub PR (`#<id>` / URL) or optional PR comment/review:** also open `{B3_HOME}/skills/engineering/code-review/references/github-pr-review.md` (external write gate: post only when requested/confirmed).
