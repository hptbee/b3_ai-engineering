---
name: review
description: One evidence-based code-review pass on the current change. Not the full independent review loop.
---

# review

**Action now:** one evidence-based review pass on the current change (diff/PR).

**Skill:** `.cursor/skills/engineering/code-review/SKILL.md`

This is **not** the full independent review loop. For the loop: `.cursor/commands/review-loop.md` and `review-loop/spec.md`.

Optional depth: `api-security`, `accessibility`, `react-performance`, `threejs-performance`, `ef-core` when those dimensions apply. Independent `performance-reviewer` only for hot-path diffs (`review-loop/strategy.md` routing) — not every PR.
