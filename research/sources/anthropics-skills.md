# anthropics/skills (reference implementation)

## Source

https://github.com/anthropics/skills

## Tier

Tier 2

## Purpose

Official Anthropic example skills, template, spec mirror, and plugin marketplace packages.

## Architecture

```
skills/
├── skill-creator/     # meta-skill with eval tooling
├── template/          # starter skill
├── docx/pdf/pptx/xlsx # production document skills (source-available)
└── …examples by domain
spec/                  # Agent Skills spec copy
```

Distributed via Claude plugin marketplace (`anthropic-agent-skills`).

## Important Patterns

- One folder per skill, self-contained SKILL.md + resources
- `skill-creator` encodes full create→eval→iterate loop
- Document skills show large reference/ script bundles for complex domains
- Disclaimer: demo/educational — production Claude may differ

## Skill Design

Follows agentskills.io. `skill-creator` recommends imperative instructions, progressive disclosure, domain-split references (aws/gcp/azure pattern).

## Rules / Instructions

Not a rules repo — skills only.

## Agents

Via plugins — not primary focus of this repo.

## Commands / Workflows

Plugin install flow; skills invokable by mention or auto-trigger.

## Evaluation

`skill-creator` includes:
- qualitative + quantitative evals
- `eval-viewer/generate_review.py`
- description optimizer script
- guidance on test prompts and variance analysis

## Portability

SKILL.md portable; plugin marketplace IDs Anthropic-specific.

## Strengths

- Realistic complex skills (PDF/DOCX) show references/scripts at scale
- Meta-skill documents eval discipline
- Template lowers authoring friction

## Weaknesses / Trade-offs

- `skill-creator/SKILL.md` is very large (~33k) — violates own "<500 lines" guidance unless heavily deferred (uses bundled scripts)
- Mixing Apache-2.0 examples with source-available document skills
- Risk of copy-paste without synthesis

## Interesting Implementation Details

- Links to agentskills.io for normative spec
- skills.sh badge integration

## Relevant Files

- `skills/skill-creator/SKILL.md` (inspected header ~120 lines via raw GitHub)
- `README.md`
- `template/`

## Evidence

- GitHub README raw (2026-09-07)
- API listing `skills/skill-creator/` contents

## Relevance to b3-ai-engineering

Primary reference for eval tooling patterns and skill authoring workflow — adapt meta-process, do not import skill pack.

## Initial Recommendation

ADAPT (eval workflow from skill-creator); OBSERVE (example domain skills)
