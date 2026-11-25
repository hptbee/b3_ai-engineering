---
name: b3-review
description: >
  One evidence-based code-review pass on the current change. Use when the
  user says review this diff, $b3-review, or /b3-review. Not the full independent
  review loop ($b3-review-loop).
---

# b3-review

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, or this repo) and run one review pass via `{B3_HOME}/skills/engineering/code-review/SKILL.md` (single-pass; never auto-fix or start `/b3-review-loop`, never load `review-loop/spec.md`; add smallest matched domain skill only):
- **Local diff/branch:** `{B3_HOME}/scripts/b3-guard.{ps1,sh} diff-scope` + `mechanical-check` (+ `symbol-check` on refactors/deletions).
- **GitHub PR / render:** read-only by default; open `{B3_HOME}/skills/engineering/code-review/references/github-pr-review.md` for PR inspection and format via `{B3_HOME}/skills/engineering/code-review/references/review-template.md`. On explicit `--post`, delegate authorized publication to `{B3_HOME}/skills/engineering/pr-feedback/SKILL.md`.
