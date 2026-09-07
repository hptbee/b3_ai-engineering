# Trail of Bits — differential-review skill

## Source

https://github.com/trailofbits/skills — `plugins/differential-review/skills/differential-review/SKILL.md`

## Tier

Tier 2

## Purpose

Security-focused differential code review skill: phased workflow, rationalizations table, adaptive depth by codebase size.

## Architecture

```text
differential-review/
├── SKILL.md           # principles, quick ref, decision tree
├── methodology.md     # phases 0-4
├── adversarial.md     # phase 5
├── reporting.md       # phase 6
└── patterns.md        # vulnerability patterns
```

- Frontmatter includes `allowed-tools: Read Write Grep Glob Bash`
- **Rationalizations anti-pattern table** — maps excuses to required actions
- Codebase size strategies: SMALL/MEDIUM/LARGE → DEEP/FOCUSED/SURGICAL
- Risk triggers: HIGH (auth, crypto, external calls, value transfer)

## Important Patterns

- **Risk-first**, evidence-based, honest coverage limits
- Mandatory git blame on removed security code
- Blast radius quantification (caller counts)
- Test coverage gaps elevate severity
- Always write markdown report file (not chat-only)
- Subagent delegation for adversarial modeling (`differential-review:adversarial-modeler`)

## Skill Design

Exemplifies **security review skill** separate from generic code-review:
- Phased workflow with progressive disclosure to methodology files
- Explicit "when NOT to use" (greenfield, docs-only, lint)
- Red flags for immediate escalation

## Rules / Instructions

Rationalizations table acts as **soft rules** inside skill — portable pattern for b3 security reviews.

## Agents

Uses namespaced subagent for adversarial phase — adapter concern for Cursor/Claude dispatch strings.

## Commands / Workflows

Phases: Pre-Analysis → Triage → Code Analysis → Test Coverage → Blast Radius → Deep Context → Adversarial → Report

## Evaluation

No published trigger evals. Description targets PR/commit/diff security review — near-miss vs generic `code-review`.

## Portability

Security method portable; `allowed-tools` and subagent names are host-specific → adapter notes only.

## Strengths

- Honest about time/depth trade-offs
- Rationalizations table prevents skim reviews
- Clear risk classification drives depth

## Weaknesses / Trade-offs

- Heavy for small personal changes — b3 should ADAPT lighter subset
- Subagent coupling reduces portability if copied verbatim
- Focused on security; not general maintainability

## Interesting Implementation Details

- Integration hooks to `audit-context-building` and `issue-writer` skills
- Example time estimates per strategy

## Relevant Files

- trailofbits/skills/plugins/differential-review/**

## Evidence

- Raw SKILL.md fetched 2026-09-07: principles, rationalizations, phases, allowed-tools, subagent note

## Relevance to b3-ai-engineering

**ADAPT** security differential patterns into b3 `code-review` security dimension or future `backend-security-review` skill — do not copy plugin tree.

## Initial Recommendation

ADAPT — rationalizations table + risk triage + report artifact; REJECT full 6-phase enterprise default for personal loop
