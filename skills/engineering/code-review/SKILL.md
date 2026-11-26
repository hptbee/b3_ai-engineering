---
name: code-review
description: Use for one evidence-based review pass on a diff, PR, or recent change (architecture, correctness, security, perf, residue, tests). Not for implementing features, full review-loop, or rubber-stamp LGTM.
---

# Code review

One honest review pass on a defined change. Iterative loops use `review-loop/strategy.md` (never load `review-loop/spec.md` on routine passes).

## When to use / not use

- **Use:** reviewing a PR, diff, or edits with separate severity, confidence, and evidence.
- **Do not use:** implementing (`problem-solving`), pattern mining (`research-engineering-patterns`), loops without `review-loop/strategy.md`, or specialist deep dives (`b3-{security,architecture,performance}-reviewer`).

Near miss: “write tests” → impl + verification. “Safe to ship?” → this skill + verification.

## Procedure

1. **Scope (delta-first)** — establish target (`delta_files` + callers first Iter 2+); empty/wrong target → `UNKNOWN / INCOMPLETE`. Skip unrelated files/logs:
   - **Local / branch diff (default):** run `b3 guard diff-scope` (`size_class` + `risk_level` / `recommended_specialists`; `NOISE_ONLY` + green checks = `PASS`; `L`/`XL`/`XXL` adds `b3 guard review-inventory`) + `mechanical-check` (+ `symbol-check` on refactors), then `git diff <base>...<target> -- <review_files>`.
   - **GitHub PR (`#<id>` / URL):** open [`references/github-pr-review.md`](references/github-pr-review.md) — `gh pr view --json ...` and filter noise first.
   - **Post to PR (`--post`):** read-only by default; delegate posting to `skills/engineering/pr-feedback/SKILL.md` (`COMMENT` default, `CONFIRMED` only).
2. **Understand** — diff-first on changed contracts/ACs; load `workflows/references/context-routing.md` on demand for symbol/impact lookup (direct-known short-circuit; native fallback on MCP failure, never false `PASS`), plus `b3 guard verify-check`/CI evidence without inventing requirements.
3. **Review (parallel `SHARED_READ_ONLY` when multi-unit/risk-triggered)** — check architecture, correctness, security, tests, maintainability; on multi-unit `review-inventory` diffs or triggered specialist scopes, fan out independent units and matched `b3-{security,architecture,performance}-reviewer` concurrently in `SHARED_READ_ONLY` (`workflows/references/dispatch-naming.md`), skipping any dimension only with recorded reason:
   - **Performance (light):** classify **CONFIRMED** (measured), **EVIDENCED RISK** (blocking `HIGH`/`MEDIUM` hot-path defect: N+1, `useFrame`+`setState`, sync CPU on request), or **SPECULATIVE** (non-blocking). Load smallest matched perf skill only; route `agents/b3-performance-reviewer.md` on hot paths only.
   - **Simplification / residue:** ask *“Is all of this code still necessary?”* Open [`references/residue-checklist.md`](references/residue-checklist.md) for non-obvious residue. Only **CONFIRMED REDUNDANCY** blocks; leave `LIKELY REDUNDANT`/`UNKNOWN` non-blocking; accept `INTENTIONAL COMPLEXITY`. Never refactor unrelated code.
4. **Deduplicate & render** — merge duplicate findings into 1 report via [`references/review-template.md`](references/review-template.md) (skip inside `/b3-review-loop` subagents, which use `agents/b3-*.md` tables): severity `CRITICAL|HIGH|MEDIUM|LOW`, `confidence` (`HIGH|MEDIUM|LOW`), `status` (`CONFIRMED|SPECULATIVE`; `LOW`-conf stays `SPECULATIVE`), `id` (`R001`…), `category`, `location`, `evidence`, fix. State violated invariant/`bug_class` and check sibling callers.
5. **Verification & boundary** — render via [`references/review-template.md`](references/review-template.md) (checks + exit codes, checked/skipped dimensions, `UNKNOWN / INCOMPLETE` on gaps, `SPECULATIVE` separate from `CONFIRMED`). Standalone `/b3-review` is single-pass only: never auto-fix or start `/b3-review-loop`.
