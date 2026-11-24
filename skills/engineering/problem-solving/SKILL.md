---
name: problem-solving
description: >
  Use for end-to-end product changes (understand -> plan -> implement ->
  verify) when no narrower skill fits. Not for debugging, plan-only,
  refactoring, code review, testing-strategy, verification, or research.
---

# Problem solving

Default engineering loop for this system:

```text
Scope → Plan → Build → Verify → Review → Fix → Verify
```

## When to use

- Feature or bug **implementation** after the cause is known or the spec is clear
- Tasks that mix investigation and change **once debugging has a cause**
- When the agent is about to jump to coding without a problem statement

## When not to use

- “Review this diff” with no implementation mandate → `code-review`
- Failure with unknown cause, before a patch → `debugging`
- “Research how other repos do X” → `research-engineering-patterns`
- Pure knowledge questions with no change
- Running the full independent review loop after work is already implemented → `review-loop/strategy.md` (not a substitute for this skill’s lighter review step)

Near miss: “is this design sound?” with no code change yet → stay in Scope/Plan; do not skip to Build.

## Procedure

1. **Scope**  
   Restate the problem, current/desired behavior, and constraints. Read known targets directly; load `workflows/references/context-routing.md` on demand for unfamiliar arch/symbols. If incomplete, gather; do not guess.

2. **Plan**  
   Write a short plan: approach, files likely touched, risks, and verification. Prefer the smallest change; call out open questions. Inside `/b3-ship`, this is `Scope` + `Gate` (inspect first, persist by `inline`/`notes`/`detailed`; do not skip or stop for the user).

3. **Build**  
   Execute the plan without silent scope expansion. If wrong, update the plan and continue.

4. **Verify**
   Run executed verification (`verification`; `b3-guard verify-run` to `.b3/ship/verify/<slug>.verify` for non-trivial changes) on current `HEAD` + tree. Missing evidence → `UNKNOWN / INCOMPLETE`.

5. **Review (risk-sensitive)**
   Run `b3-guard diff-scope` + `mechanical-check` (+ `symbol-check` on refactors) first; check plan alignment, callers, tests, and `CONFIRMED` residue:
   - **Low-risk:** 1 focused independent `b3-reviewer` pass if subagents exist (else self-review noting single-agent limit).
   - **High-risk** (authz, data/schema, concurrency/state, hot perf, cross-module contracts): add matching `b3-{security,architecture,performance}-reviewer`. Not `/b3-review-loop` or `/b3-ship`.

6. **Fix**
   Fix confirmed causes in scope, add regression tests, delete only `CONFIRMED` redundancy (`LIKELY REDUNDANT`/`INTENTIONAL COMPLEXITY` untouched); map each edit to a finding.

7. **Verify (re-run)**
   Re-run checks + fresh delta review if blockers existed (max 2 fix-verify rounds). Still blocked → `FAIL`/`INCOMPLETE` or suggest `/b3-review-loop` (never silently escalate).

## Progressive disclosure

- Constraints: `rules/engineering-principles.md`, `rules/verification.md`
- Full loop / review: `review-loop/strategy.md`, `skills/engineering/code-review/SKILL.md`

## Verification

Done only when the success condition is checked with evidence, or gaps are labeled incomplete. Untested code is not done.

## Failure handling

- Cannot reproduce → debug with evidence; do not patch by folklore
- Multiple plausible causes → test the cheapest distinguishing hypothesis
- Fix unverified because tools are missing → incomplete, not success
- Problem is out of scope (needs a specialist skill that does not exist yet) → say so; do not invent a giant ad-hoc skill in-line
