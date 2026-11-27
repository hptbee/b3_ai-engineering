---
name: problem-solving
description: Use for end-to-end product changes (understand -> plan -> implement -> verify) when no narrower skill fits. Not for debugging, plan-only, refactoring, code review, testing-strategy, verification, or research.
---

# Problem solving

Default engineering loop:

```text
Scope → Plan → Build → Verify → Review → Fix → Verify
```

## When to use / not use

- **Use:** feature/bug implementation once cause is known or spec is clear, or mixed investigation+change after debugging finds a cause.
- **Do not use:** review-only (`code-review`), unknown-cause failures before patching (`debugging`), external pattern mining (`research-engineering-patterns`), pure Q&A, or full independent loop (`review-loop/strategy.md`).
- Near miss: “is this design sound?” without code changes → stay in Scope/Plan.

## Procedure

1. **Scope** — Restate problem, current/desired behavior, and constraints. Read known targets directly; load `workflows/references/context-routing.md` on demand for unfamiliar arch/symbols. Gather gaps; do not guess.
2. **Plan** — Write a short plan: approach, disjoint `files`/`depends_on`, risks, and verification (smallest change; flag open questions). Inside `/b3-ship`, this is `Scope` + `Gate`.
3. **Build** — Execute without silent scope expansion (`dispatch-naming.md`): 1-slice `XS` runs inline; for independent impl/test/doc slices, validate via `b3 guard check-wave --partition` and dispatch concurrent disjoint workers (single-writer parent integration). Do not force `/b3-ship`.
4. **Verify** — Run executed checks (`verification`; `b3 guard verify-run` to `.b3/ship/verify/<slug>.verify` for non-trivial changes) on current `HEAD` + tree. Missing evidence → `UNKNOWN / INCOMPLETE`.
5. **Review (risk-sensitive)** — Run `b3 guard diff-scope` + `mechanical-check` (+ `symbol-check` on refactors) first; check plan alignment, callers, tests, and `CONFIRMED` residue:
   - **Low-risk:** 1 `b3-reviewer` pass if subagents exist (else self-review noting `SINGLE_AGENT_LIMIT`).
   - **High-risk** (authz, schema, concurrency, hot perf, shared contracts): fan out `b3-reviewer` + matching `b3-{security,architecture,performance}-reviewer` concurrently in `SHARED_READ_ONLY` (`SINGLE_AGENT_LIMIT` caps to `INCOMPLETE`). Not `/b3-review-loop` or `/b3-ship`.
6. **Fix** — Fix confirmed causes in scope, add regression tests, act only on `CONFIRMED REDUNDANCY` or evidenced `CONFIRMED` overengineering (concrete simpler alt meeting all security/correctness/portability/compat/perf reqs — never LOC alone; leave `SPECULATIVE`/`INTENTIONAL COMPLEXITY`/`UNKNOWN` untouched); map each edit to a finding.
7. **Verify (re-run)** — Re-run checks + fresh delta review if blockers existed (max 2 fix-verify rounds). Still blocked → `FAIL`/`INCOMPLETE` or suggest `/b3-review-loop` (never silently escalate).

## Progressive disclosure

- Constraints & orchestration: `rules/engineering-principles.md`, `rules/verification.md`, `workflows/references/dispatch-naming.md`
- Full loop / review: `review-loop/strategy.md`, `skills/engineering/code-review/SKILL.md`

## Verification & failure handling

- Done only when success conditions are checked with evidence, or gaps are labeled `UNKNOWN / INCOMPLETE`. Untested code is not done.
- Cannot reproduce → `debugging`; multiple plausible causes → test cheapest distinguishing hypothesis; missing tools → `INCOMPLETE`; missing specialist skill → say so cleanly.
