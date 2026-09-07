# Progressive disclosure

## Observation

Production systems use a **three-tier load model**: metadata always → SKILL.md on activation → bundled files/scripts only when needed.

## Evidence

- agentskills.io spec (token budgets: ~100 metadata, <5000 body, unlimited resources)
- Cursor/Claude docs mirror same model
- anthropics skill-creator: TOC for large references; domain-split reference files (aws/gcp/azure pattern)
- Microsoft Agent Framework: explicit `load_skill` / `read_skill_resource` tools

## Pattern

Keep SKILL.md procedural and short; move encyclopedic content to `references/`; use scripts for repetitive mechanical steps.

## Why it matters

Always-on context is the scarcest resource. AGENTS.md bloat and giant SKILL.md files both fail for the same reason.

## Trade-offs

Over-splitting forces many file reads and unclear "when to open what" unless SKILL.md indexes references clearly

## Potential application

Already in b3 skill standard. Enforce during synthesis: if SKILL.md > ~200 lines, split with explicit open-when table.

## Confidence

High
