---
name: b3-review
description: "Single-pass evidence-based review of a diff or PR via code-review skill ($b3-review, /b3-review). Not for baseline /b3-audit or /b3-review-loop."
---

# b3-review

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, host global fallback, or this repo) and run one review pass via `{B3_HOME}/skills/engineering/code-review/SKILL.md` (single-pass; never auto-fix or start `/b3-review-loop`, never load `review-loop/spec.md`; add smallest matched domain skill only):
- **Local diff/branch:** `b3 guard diff-scope` + `mechanical-check` (+ `symbol-check` on refactors/deletions); fan out independent (L/XL/XXL) `review-inventory` units + risk-triggered specialists concurrently in `SHARED_READ_ONLY` (`{B3_HOME}/workflows/references/dispatch-naming.md`), deduplicating into 1 report.
- **GitHub PR / render:** read-only by default; open `{B3_HOME}/skills/engineering/code-review/references/github-pr-review.md` for PR inspection and format via `{B3_HOME}/skills/engineering/code-review/references/review-template.md`. On explicit `--post`, delegate authorized publication to `{B3_HOME}/skills/engineering/pr-feedback/SKILL.md`.
