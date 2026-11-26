---
name: code-review
description: Use for one evidence-based review pass on a diff, PR, or recent change (architecture, correctness, security, perf, residue, tests). Not for implementing features, full review-loop, or rubber-stamp LGTM.
---

# Code review

Produce one honest review pass on a defined change. Iterative loops use `review-loop/strategy.md` (never load `review-loop/spec.md` on routine passes).

## When to use / not use

- **Use:** reviewing a PR, diff, or recent edits with separate severity, confidence, and evidence.
- **Do not use:** implementing (`problem-solving`), pattern mining (`research-engineering-patterns`), multi-iteration loops without `review-loop/strategy.md`, or specialist deep dives (`b3-{security,architecture,performance}-reviewer`).

Near miss: “write tests” → impl + verification. “Safe to ship?” → this skill + verification.

## Procedure

1. **Scope (delta-first)** — establish target (`delta_files` + callers first Iter 2+); empty/wrong target → `UNKNOWN / INCOMPLETE`. Skip unrelated files/historical logs:
   - **Local / branch diff (default, any Git host):** run `scripts/b3-guard.{ps1,sh} diff-scope` (`size_class` + `risk_level` / `recommended_specialists`; `NOISE_ONLY` + green checks = `PASS`; `L`/`XL`/`XXL` adds `review-inventory`) + `mechanical-check` (+ `symbol-check` on refactors), then `git diff <base>...<target> -- <review_files>`.
   - **Optional GitHub PR helper (`#<id>` / URL):** open [`references/github-pr-review.md`](references/github-pr-review.md) — `gh pr view --json ...` and filter noise before diffs.
   - **Post to PR (`--post`):** read-only by default; delegate authorized posting to `skills/engineering/pr-feedback/SKILL.md` (`COMMENT` default, `CONFIRMED` only).
2. **Understand** — diff-first on changed contracts/ACs; load `workflows/references/context-routing.md` on demand for targeted symbol/impact lookup (direct-known short-circuit; native fallback on MCP failure, never false `PASS`), plus `b3-guard verify-check`/CI evidence (never trust self-reported pass claims) without inventing requirements.
3. **Review** — check architecture, correctness, security, tests, maintainability, plus (skip any dimension only with recorded reason):
   - **Performance (light):** classify **CONFIRMED** (measured), **EVIDENCED RISK** (blocking `HIGH`/`MEDIUM` hot-path defect: N+1, `useFrame`+`setState`, sync CPU on request), or **SPECULATIVE** (non-blocking). Load smallest matched perf skill only; route `agents/b3-performance-reviewer.md` on hot paths only.
   - **Simplification / residue:** ask *“Is this code necessary, or could a simpler alternative work?”* Open [`references/residue-checklist.md`](references/residue-checklist.md). Block only on **CONFIRMED** redundancy/evidenced overengineering; leave `SPECULATIVE`/`UNKNOWN` non-blocking; accept `INTENTIONAL COMPLEXITY`. Don't touch unrelated code.
4. **Record & render cleanly** — use [`references/review-template.md`](references/review-template.md) for standalone `/b3-review` and PR reviews (skip inside `/b3-review-loop` subagents, which use `agents/b3-*.md`'s compact table): fixed severity `CRITICAL` | `HIGH` | `MEDIUM` | `LOW` (never `Must/Should` or `P0/P1/P2`), separate `confidence` (`HIGH`/`MEDIUM`/`LOW`), `status` (`CONFIRMED`/`SPECULATIVE`; any `LOW`-confidence item stays `SPECULATIVE`), `id` (`R001`…), `category` (`correctness`/`security`/`performance`/`architecture`/`simplification`/`maintainability`/`testing`/`reliability`/`ux`), `location`, `evidence`, and fix. State violated invariant/`bug_class`, check sibling callers in scope, and merge duplicates.
5. **Verification & pass boundary** — render standalone/PR report via [`references/review-template.md`](references/review-template.md) (checks + exit codes, checked/skipped dimensions, `UNKNOWN / INCOMPLETE` on tool/check gaps, `SPECULATIVE` separate from `CONFIRMED`). Standalone `/b3-review` is single-pass only: never auto-fix or start `/b3-review-loop`.
