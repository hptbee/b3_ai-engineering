---
name: problem-solving
description: >
  Use when tackling a software problem end to end: a bug, a feature, an
  architecture question that will lead to change, or an unclear failure.
  Use when the work needs understand → plan → implement → verify, not a
  single specialized review. Do not use for isolated code review of an
  existing diff, for research-only pattern mining, or for host-tool setup.
---

# Problem solving

Default engineering loop for this system:

```text
Understand → Plan → Implement → Verify → Review → Fix → Re-verify
```

## When to use

- Feature work or bug work in a product repo
- Production failures, regressions, or “it doesn’t work”
- Tasks that mix investigation and change
- When the agent is about to jump to coding without a problem statement

## When not to use

- “Review this diff” with no implementation mandate → `code-review`
- “Research how other repos do X” → `research-engineering-patterns`
- Pure knowledge questions with no change
- Running the full independent review loop after work is already implemented → `docs/review-loop.md` (specified; not a substitute for this skill’s lighter review step)

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
- Full independent loop (when that machinery exists): `docs/review-loop.md`
- Review method: `skills/engineering/code-review/SKILL.md`

## Verification

The loop is done only when the success condition was checked with evidence, or the leftover gap is labeled incomplete. A plan plus untested code is not done.

## Failure handling

- Cannot reproduce → debug with evidence; do not patch by folklore
- Multiple plausible causes → test the cheapest distinguishing hypothesis
- Fix unverified because tools are missing → incomplete, not success
- Problem is out of scope (needs a specialist skill that does not exist yet) → say so; do not invent a giant ad-hoc skill in-line
