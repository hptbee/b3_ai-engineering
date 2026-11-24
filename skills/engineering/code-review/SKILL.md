---
name: code-review
description: >
  Use for one evidence-based review pass on a diff, PR, or recent change
  (architecture, correctness, security, perf, residue, tests). Not for
  implementing features, full review-loop, or rubber-stamp LGTM.
---

# Code review

Produce one honest review pass on a defined change. Iterative loops use `review-loop/strategy.md` (never load `review-loop/spec.md` on routine passes).

## When to use / not use

- **Use:** reviewing a PR, diff, or recent edits with separate severity, confidence, and evidence.
- **Do not use:** implementing (`problem-solving`), pattern mining (`research-engineering-patterns`), multi-iteration loops without `review-loop/strategy.md`, or specialist deep dives (`b3-{security,architecture,performance}-reviewer`).

Near miss: “write tests” → impl + verification. “Safe to ship?” → this skill + verification.

## Procedure

1. **Scope (delta-first)** — establish target (`delta_files` + callers first Iter 2+); empty/wrong target → `UNKNOWN / INCOMPLETE`. Skip unrelated files/historical logs:
   - **Local (default):** run `scripts/b3-guard.{ps1,sh} diff-scope` (`size_class` + `risk_level` / `recommended_specialists`; `NOISE_ONLY` + green checks = `PASS`; `L`/`XL`/`XXL` adds `review-inventory`) + `mechanical-check`, plus `symbol-check` on refactors.
   - **GitHub PR (`#<id>` / URL):** open [`references/github-pr-review.md`](references/github-pr-review.md) — `gh pr view --json ...` and filter noise before diffs.
   - **Post to PR:** follow [`references/github-pr-review.md`](references/github-pr-review.md) gates + `--body-file` / `gh api .../reviews --input` (`COMMENT` default, `CONFIRMED` only, user-confirmed).
2. **Understand** — inspect changed contracts/ACs (PR/ticket intent if present) and verification evidence (`b3-guard verify-check` on `.verify` receipts or CI checks; never trust self-reported pass claims) without inventing requirements.
3. **Review** — check architecture, correctness, security, tests, maintainability, plus (skip any dimension only with recorded reason):
   - **Performance (light):** classify **CONFIRMED** (measured), **EVIDENCED RISK** (blocking `HIGH`/`MEDIUM` hot-path defect: N+1, `useFrame`+`setState`, sync CPU on request), or **SPECULATIVE** (non-blocking). Load smallest matched perf skill only; route `agents/b3-performance-reviewer.md` on hot paths only.
   - **Simplification / residue:** ask *“Is all of this code still necessary?”* Open [`references/residue-checklist.md`](references/residue-checklist.md) for non-obvious residue. Only **CONFIRMED REDUNDANCY** blocks; leave `LIKELY REDUNDANT` / `UNKNOWN` non-blocking; accept `INTENTIONAL COMPLEXITY`. Never refactor unrelated code.
4. **Record & render cleanly** — use [`references/review-template.md`](references/review-template.md) for standalone `/b3-review` and GitHub PR reviews (skip inside `/b3-review-loop` subagents, which use `agents/b3-*.md`'s compact table): fixed severity `CRITICAL` | `HIGH` | `MEDIUM` | `LOW` (never `Must/Should` or `P0/P1/P2`), separate `confidence` (`HIGH`/`MEDIUM`/`LOW`), `status` (`CONFIRMED`/`SPECULATIVE`; any `LOW`-confidence item stays `SPECULATIVE`), `id` (`R001`…), `category` (`correctness`/`security`/`performance`/`architecture`/`simplification`/`maintainability`/`testing`/`reliability`/`ux`), `location`, `evidence`, and fix. State violated invariant/`bug_class`, check sibling callers in scope, and merge duplicates.
5. **Verification & pass boundary** — render standalone/PR report via [`references/review-template.md`](references/review-template.md) (checks + exit codes, checked/skipped dimensions, `UNKNOWN / INCOMPLETE` on tool/check gaps, `SPECULATIVE` separate from `CONFIRMED`). Standalone `/b3-review` is single-pass only: never auto-fix or start `/b3-review-loop`.
