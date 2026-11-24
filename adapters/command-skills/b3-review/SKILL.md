---
name: b3-review
description: >
  One evidence-based code-review pass on the current change. Use when the
  user says review this diff, $b3-review, or /b3-review. Not the full independent
  review loop ($b3-review-loop).
---

# b3-review

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, or this repo) and run one review pass via `{B3_HOME}/skills/engineering/code-review/SKILL.md` (single-pass; not `/b3-review-loop`; load matched domain skill only):
- **Local diff/branch:** `b3-guard.{ps1,sh} diff-scope` + `mechanical-check` (+ `symbol-check` on refactors/deletions).
- **GitHub PR / render:** open `skills/engineering/code-review/references/github-pr-review.md` for PRs (user-confirmed posting); format with `skills/engineering/code-review/references/review-template.md`.
