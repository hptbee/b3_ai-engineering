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
- **Do not use:** implementing features (`problem-solving`), external pattern mining (`research-engineering-patterns`), running a multi-iteration loop without `review-loop/strategy.md`, or specialist deep dives (`b3-security-reviewer`, `b3-architecture-reviewer`, hot-path `b3-performance-reviewer`).

Near miss: “write tests” → implementation + verification. “Safe to ship?” → this skill + executed verification.

## Procedure

1. **Scope (delta-first)** — establish target (`delta_files` + boundary callers first on Iteration 2+); empty/wrong target → `UNKNOWN / INCOMPLETE`. Never read full large diffs, unrelated files, historical logs, or full test logs unnecessarily:
   - **Local (default):** run `scripts/b3-guard.{ps1,sh} diff-scope` (auto `HEAD`/merge-base; filters noise; `NOISE_ONLY` + green checks = `PASS`) + `mechanical-check` (`safety_hits`, `0 LLM tokens`), plus `symbol-check` on refactors.
   - **GitHub PR (`#<id>` / URL):** open [`references/github-pr-review.md`](references/github-pr-review.md) — `gh pr view --json ...` and filter noise before diffs.
   - **Post to PR:** follow [`references/github-pr-review.md`](references/github-pr-review.md) gates + `--body-file` / `gh api .../reviews --input` (`COMMENT` default, `CONFIRMED` only, user-confirmed).
2. **Understand** — inspect changed contracts/ACs (PR/ticket intent if present) and verification evidence (`b3-guard verify-check` on `.verify` receipts or CI checks; never trust self-reported pass claims) without inventing requirements.
3. **Review** — check architecture, correctness, security, tests, maintainability, plus (skip any dimension only with recorded reason):
   - **Performance (light):** classify **CONFIRMED** (measured), **EVIDENCED RISK** (known hot-path defect: N+1, `useFrame`+`setState`, sync CPU on request), or **SPECULATIVE** (non-blocking). Load smallest stack perf skill if matched; route `agents/b3-performance-reviewer.md` on hot paths only.
   - **Simplification / residue:** ask *“Is all of this code still necessary?”* Open [`references/residue-checklist.md`](references/residue-checklist.md) for non-obvious residue. Only **CONFIRMED REDUNDANCY** blocks; leave `LIKELY REDUNDANT` / `UNKNOWN` non-blocking; accept `INTENTIONAL COMPLEXITY`. Never refactor unrelated code.
4. **Record & consolidate** — use `id` (`R001`…), `severity` (`critical`/`high`/`medium`/`low`), `confidence` (`high`/`medium`/`low`), `status` (`CONFIRMED`/`SPECULATIVE`), `category` (`correctness`/`security`/`performance`/`architecture`/`simplification`/`maintainability`/`testing`/`reliability`/`ux`), `location`, `description`, `evidence`, `verification`. For every `CONFIRMED` defect, state the violated invariant/`bug_class`, check sibling callers/entry points in scope, and merge duplicates (if 0 findings, list checked/skipped dimensions).
5. **Verification & pass boundary** — list executed checks + exit codes, explicit unverified/skipped dimensions (`UNKNOWN / INCOMPLETE` on tool/check gaps), and keep `SPECULATIVE` separate from `CONFIRMED`. Standalone `/b3-review` is single-pass only: never auto-fix or start `/b3-review-loop`.
