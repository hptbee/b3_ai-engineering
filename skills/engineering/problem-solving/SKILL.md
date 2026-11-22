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
- Running the full independent review loop after work is already implemented → `review-loop/strategy.md` (specified; not a substitute for this skill’s lighter review step)

Near miss: “is this design sound?” with no code change yet → stay in Scope/Plan; do not skip to Build.

## Procedure

1. **Scope**  
   Restate the problem, current behavior, desired behavior, and constraints. Read the relevant code and failure evidence. If understanding is incomplete, stop and gather; do not guess a root cause.

2. **Plan**  
   Write a short plan: approach, files likely touched, risks, and how success will be verified. Prefer the smallest change. Call out open questions. Inside `/b3-ship`, this step is `Scope` + `Gate` (Implementation Readiness Gate): inspect code first, then persist by **depth** (`inline` / `notes` / `detailed`). Do not skip it. Do not stop for the user after it.

3. **Build**  
   Execute the plan. Do not silently expand scope. If the plan is wrong, update the plan, then continue.

4. **Verify**  
   Use the `verification` skill. No evidence → `UNKNOWN / INCOMPLETE`.

5. **Review**  
   Check the change against the plan, obvious failure modes (correctness, tests, security if in play), and **simplification / implementation residue** (did earlier attempts, intermediate fixes, or scaffolding leave behind dead branches, redundant state, or temporary workarounds?). This is not the full review loop.

6. **Fix**  
   Address confirmed findings (and high-confidence issues still `INVESTIGATING` if they block the success condition). For simplification findings, remove only CONFIRMED redundancy; preserve intentional complexity. Map each fix to a finding.

7. **Verify (re-run)**  
   Re-run the checks that matter. Then stop or escalate.

## Progressive disclosure

- Constraints: `rules/engineering-principles.md`, `rules/verification.md`
- Full independent loop: `review-loop/strategy.md`
- Review method: `skills/engineering/code-review/SKILL.md`

## Verification

The loop is done only when the success condition was checked with evidence, or the leftover gap is labeled incomplete. A plan plus untested code is not done.

## Failure handling

- Cannot reproduce → debug with evidence; do not patch by folklore
- Multiple plausible causes → test the cheapest distinguishing hypothesis
- Fix unverified because tools are missing → incomplete, not success
- Problem is out of scope (needs a specialist skill that does not exist yet) → say so; do not invent a giant ad-hoc skill in-line
