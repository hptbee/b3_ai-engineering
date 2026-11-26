---
name: b3-review
description: One evidence-based code-review pass on the current change. Not the full independent review loop.
---

# b3-review

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, host global fallback, or this repo) and run one review pass via `{B3_HOME}/skills/engineering/code-review/SKILL.md` (single-pass; never auto-fix or start `/b3-review-loop`, never load `review-loop/spec.md`; add smallest matched domain skill only):
- **Local diff/branch (provider-neutral):** run `b3-guard.{ps1,sh} diff-scope` + `mechanical-check` (+ `symbol-check` on refactors/deletions) and render findings with `references/review-template.md` without requiring a remote provider.
- **Optional GitHub PR / publication:** read-only by default via `{B3_HOME}/skills/engineering/code-review/references/github-pr-review.md` when inspecting a GitHub PR; on explicit `--post`, delegate authorized publication to `{B3_HOME}/skills/engineering/pr-feedback/SKILL.md`.
