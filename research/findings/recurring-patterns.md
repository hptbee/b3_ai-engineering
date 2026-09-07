# Recurring patterns

Patterns appearing **independently** across multiple strong sources (not copied from one README).

---

## Progressive disclosure (SKILL.md)

| Field | Value |
| --- | --- |
| **Pattern** | Metadata → body → references/scripts on demand |
| **Independent sources** | 6+ (agentskills spec, Cursor, Claude, Codex, MS Agent Framework, skill-creator) |
| **Examples** | `agentskills-open-standard.md`, `cursor-agent-skills.md`, `claude-code-skills-plugins.md` |
| **Why recurring** | Context window economics; skills catalogs scale only if metadata is small |
| **Confidence** | High |
| **Potential adoption** | ADOPT — already in b3 |

---

## Description-driven skill activation

| Field | Value |
| --- | --- |
| **Pattern** | `description` frontmatter is primary trigger surface |
| **Independent sources** | 5+ (spec, Cursor, Claude, Codex, skill-creator, dreaming.press) |
| **Examples** | `agentskills-open-standard.md`, `skill-triggering.md` finding |
| **Why recurring** | Body not loaded until after selection decision |
| **Confidence** | High |
| **Potential adoption** | ADOPT + build eval fixtures |

---

## AGENTS.md as always-on project router

| Field | Value |
| --- | --- |
| **Pattern** | Short always-on markdown; nested for monorepos; user overrides win |
| **Independent sources** | 4+ (agents.md, Codex, Cursor, Claude bridge docs) |
| **Examples** | `agents-md-open-format.md`, `openai-codex-customization.md` |
| **Why recurring** | Cross-vendor need for stable project context without proprietary formats |
| **Confidence** | High |
| **Potential adoption** | ADOPT — keep b3 AGENTS.md concise |

---

## Rules vs skills separation

| Field | Value |
| --- | --- |
| **Pattern** | Constraints/rules always-on or scoped; procedures in skills on demand |
| **Independent sources** | 4+ (Cursor migration, Cursor rules doc, Codex customization, Superpowers decomposition) |
| **Examples** | `cursor-rules-agents-md.md`, `startdebugging-cursor-migration.md` |
| **Why recurring** | Prevents token bloat and ambiguous activation |
| **Confidence** | High |
| **Potential adoption** | ADOPT — b3 taxonomy validated |

---

## Independent reviewer / subagent

| Field | Value |
| --- | --- |
| **Pattern** | Reviewer without implementer context or with explicit isolation |
| **Independent sources** | 4 (SWE-Review, dev-loop cross-model, OCR parallel reviewers, Cursor verifier subagent guidance) |
| **Examples** | `swe-lego-cc-swe-review.md`, `mintmcp-dev-loop.md` |
| **Why recurring** | Mitigates anchoring and self-LGTM |
| **Confidence** | High |
| **Potential adoption** | ADAPT into review-loop runtime |

---

## Iteration caps on review/fix loops

| Field | Value |
| --- | --- |
| **Pattern** | Max rounds/iterations; stop ≠ success |
| **Independent sources** | 4 (SWE-Review 3, dev-loop 4, Anthropic stopping conditions, b3 spec) |
| **Examples** | `swe-lego-cc-swe-review.md`, `mintmcp-dev-loop.md` |
| **Why recurring** | Cost control + avoid infinite churn |
| **Confidence** | High |
| **Potential adoption** | ADOPT — already in b3 docs |

---

## Validate findings before fixing

| Field | Value |
| --- | --- |
| **Pattern** | Discard or downgrade unvalidated review noise before edits |
| **Independent sources** | 3 (dev-loop, calimero consensus, OCR discourse/dedup) |
| **Examples** | `mintmcp-dev-loop.md`, `calimero-ai-code-reviewer.md` |
| **Why recurring** | False positives cause harmful drive-by refactors |
| **Confidence** | Medium-High |
| **Potential adoption** | ADAPT in review-loop verification phase |

---

## Portable core + host adapters

| Field | Value |
| --- | --- |
| **Pattern** | Standard SKILL.md/AGENTS.md at repo root; host paths in adapters |
| **Independent sources** | 4+ (agentskills, Cursor multi-path load, VoltAgent table, b3 design) |
| **Examples** | `portability.md` finding, `voltagent-awesome-agent-skills.md` |
| **Why recurring** | Multi-tool teams cannot maintain forked skill packs |
| **Confidence** | High |
| **Potential adoption** | ADOPT — core architectural bet validated |

---

## Composable small skills (not monoliths)

| Field | Value |
| --- | --- |
| **Pattern** | Many focused skills vs one "engineering everything" pack |
| **Independent sources** | 3 (Superpowers, anthropics examples, Cursor built-in skill set) |
| **Examples** | `obra-superpowers.md`, `anthropics-skills.md` |
| **Why recurring** | Trigger precision and maintenance |
| **Confidence** | Medium-High |
| **Potential adoption** | ADOPT — already b3 philosophy |

---

## Note on non-independent clusters

Several review-loop repos share Claude Code plugin patterns (hooks, `.claude-plugin/`) — treat as **one ecosystem cluster** plus SWE-Review research lineage, not fully independent statistical evidence.
