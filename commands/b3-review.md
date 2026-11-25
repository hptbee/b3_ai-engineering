---
name: b3-review
description: One evidence-based code-review pass on the current change. Not the full independent review loop.
---

# b3-review

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, or this repo) and run one review pass via `{B3_HOME}/skills/engineering/code-review/SKILL.md` (single-pass; never auto-fix or start `/b3-review-loop`, never load `review-loop/spec.md`; add smallest matched domain skill only):
- **Local diff/branch:** `b3-guard.{ps1,sh} diff-scope` + `mechanical-check` (+ `symbol-check` on refactors/deletions).
- **GitHub PR / render:** read-only by default; add `{B3_HOME}/skills/engineering/code-review/references/github-pr-review.md` for PR inspection and format via `references/review-template.md`. On explicit `--post`, delegate authorized publication to `{B3_HOME}/skills/engineering/pr-feedback/SKILL.md`.
