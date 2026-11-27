---
name: code-review
description: Use for one evidence-based review pass on a diff, PR, or recent change (architecture, correctness, security, perf, residue, tests). Not for implementing features, full review-loop, or rubber-stamp LGTM.
---

# Code review

One honest review pass on a defined change. Loops use `review-loop/strategy.md` (skip `review-loop/spec.md`).

## When to use / not use

- **Use:** reviewing a PR, diff, or edits with separate severity, confidence, and evidence.
- **Do not use:** implementing (`problem-solving`), pattern mining (`research-engineering-patterns`), loops (`review-loop/strategy.md`), or specialist deep dives (`b3-{security,architecture,performance}-reviewer`).

Near miss: “write tests” → impl + verify. “Safe to ship?” → this skill + verification.

## Procedure

1. **Scope (delta-first)** — target (`delta_files` + callers Iter 2+); empty/wrong → `UNKNOWN / INCOMPLETE`. Skip unrelated files/logs:
   - **Local / branch diff:** `b3 guard diff-scope` (`size_class`, `risk_level`, `recommended_specialists`; `NOISE_ONLY` + green checks = `PASS`; `L`/`XL`/`XXL` adds `review-inventory`) + `mechanical-check` (+ `symbol-check` on refactors), then `git diff <base>...<target> -- <review_files>`. Fix/block `exit 2` (`MECHANICAL_FINDINGS`/`SYMBOL_FINDINGS` `dangling_refs`; proven textual FP noted); triage `exit 0` `MECHANICAL_ADVISORY` (`advisory_hits=`)/`SYMBOL_ADVISORY` (`orphan_internal`) w/ native compiler/linter output (no mechanical block).
   - **GitHub PR (`#<id>` / URL):** open [`references/github-pr-review.md`](references/github-pr-review.md) — `gh pr view --json ...`, filter noise first.
   - **Post (`--post`):** read-only default; post via `skills/engineering/pr-feedback/SKILL.md` (`COMMENT` default, `CONFIRMED` only).
2. **Understand** — diff-first on contracts/ACs; `workflows/references/context-routing.md` on demand (native fallback on MCP fail, never false `PASS`), plus `b3 guard verify-check`/CI evidence.
3. **Review (parallel `SHARED_READ_ONLY` on multi-unit/risk)** — check arch, correctness, security, tests, maintainability; fan out `review-inventory` units + `b3-{security,architecture,performance}-reviewer` in `SHARED_READ_ONLY` (`workflows/references/dispatch-naming.md`), recording skipped dimensions:
   - **Performance (light):** **CONFIRMED** (measured), **EVIDENCED RISK** (`HIGH`/`MEDIUM` hot-path defect: N+1, `useFrame`+`setState`, sync CPU on request), or **SPECULATIVE** (non-blocking). Load smallest perf skill; route `b3-performance-reviewer.md` on hot paths.
   - **Simplification / residue:** *“Is this code necessary, or a simpler alt works?”* Open [`references/residue-checklist.md`](references/residue-checklist.md). Local diff only (system shape → `b3-architecture-reviewer`/`simplest-correct`). Block only on `CONFIRMED REDUNDANCY`/evidenced `CONFIRMED` overengineering (concrete simpler alt meeting all security/correctness/portability/compat/perf reqs, never LOC alone); keep `SPECULATIVE`/`UNKNOWN` non-blocking; accept `INTENTIONAL COMPLEXITY`. Never refactor unrelated code.
4. **Deduplicate & render** — merge into [`references/review-template.md`](references/review-template.md) (skip in `/b3-review-loop` subagents): `CRITICAL|HIGH|MEDIUM|LOW`, `confidence`, `status` (`CONFIRMED|SPECULATIVE`; `LOW`-conf stays `SPECULATIVE`), `id` (`R001`…), `category`, `location`, `evidence`, fix. State invariant/`bug_class` + sibling callers.
5. **Verification & boundary** — render via [`references/review-template.md`](references/review-template.md) (checks + exits, checked/skipped dims, `UNKNOWN / INCOMPLETE` on gaps, `SPECULATIVE` separate). Standalone `/b3-review` is single-pass only: never auto-fix or start `/b3-review-loop`.
