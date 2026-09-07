---
name: problem-solving
description: >
  Use when executing a product change end to end (understand → plan →
  implement → verify) and no more specific skill covers the whole task.
  Do not use for root-cause investigation before a patch (debugging),
  plan-only requests, structure-only refactors, isolated code review,
  choosing tests, claiming tests passed, or research-only pattern mining.
---

# Problem solving

Default engineering loop for this system:

```text
Understand → Plan → Implement → Verify → Review → Fix → Re-verify
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
- Running the full independent review loop after work is already implemented → `review-loop/spec.md` (specified; not a substitute for this skill’s lighter review step)

Near miss: “is this design sound?” with no code change yet → stay in Understand/Plan; do not skip to Implement.

## Procedure

1. **Understand**  
   Restate the problem, the current behavior, the desired behavior, and constraints. Read the relevant code and failure evidence. If understanding is incomplete, stop and gather; do not guess a root cause.

2. **Plan**  
   Write a short plan: approach, files likely touched, risks, and how success will be verified. Prefer the smallest change. Call out open questions.

3. **Implement**  
   Execute the plan. Do not silently expand scope. If the plan is wrong, update the plan, then continue.

4. **Verify**  
   Use the `verification` skill. No evidence → `UNKNOWN / INCOMPLETE`.

5. **Review**  
   Check the change against the plan and obvious failure modes (correctness, tests, security if in play). This is not the full review loop.

6. **Fix**  
   Address confirmed findings (and high-confidence issues still `INVESTIGATING` if they block the success condition). Map each fix to a finding.

7. **Re-verify**  
   Re-run the checks that matter. Then stop or escalate.

## Progressive disclosure

- Constraints: `rules/engineering-principles.md`, `rules/verification.md`
- Full independent loop (when that machinery exists): `review-loop/spec.md`
- Review method: `.cursor/skills/engineering/code-review/SKILL.md`

## Verification

The loop is done only when the success condition was checked with evidence, or the leftover gap is labeled incomplete. A plan plus untested code is not done.

## Failure handling

- Cannot reproduce → debug with evidence; do not patch by folklore
- Multiple plausible causes → test the cheapest distinguishing hypothesis
- Fix unverified because tools are missing → incomplete, not success
- Problem is out of scope (needs a specialist skill that does not exist yet) → say so; do not invent a giant ad-hoc skill in-line
