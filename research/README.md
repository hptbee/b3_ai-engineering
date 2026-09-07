# Research Phase 1 — Agent Engineering Foundations

Research-only phase. **No implementation** outside `research/` was performed. Synthesis into `skills/`, `rules/`, `docs/`, etc. is the **next phase**.

## Scope

Investigated how reliable, portable AI-assisted software engineering systems are structured across:

| Area | Researched |
| --- | --- |
| Skills | ✓ |
| Rules / persistent instructions | ✓ |
| AGENTS.md / project guidance | ✓ |
| Commands / slash commands | ✓ (as skills + host mappings) |
| Subagents / specialized agents | ✓ |
| Workflows / orchestration | ✓ |
| Context engineering | ✓ |
| Review loops | ✓ |
| Evaluation | ✓ |
| Portability (Cursor / Codex / Claude Code) | ✓ |

Method: `docs/research-methodology.md` (in portable core — not modified this phase).

## Lifecycle (this repo)

```text
External Sources  →  research/sources/
        ↓
   Findings        →  research/findings/
        ↓
 Comparisons      →  research/comparisons/
        ↓
   Decisions       →  research/decisions/
        ↓
 (Next phase) Knowledge / Skills / Rules / Adapters
```

Rejected ideas: `research/rejected/`

---

## Sources (19)

### Tier 1 — Official / authoritative (8)

| Source file | Topic |
| --- | --- |
| [sources/cursor-agent-skills.md](sources/cursor-agent-skills.md) | Cursor Agent Skills docs |
| [sources/cursor-rules-agents-md.md](sources/cursor-rules-agents-md.md) | Cursor rules + AGENTS.md |
| [sources/cursor-subagents.md](sources/cursor-subagents.md) | Cursor subagents |
| [sources/claude-code-skills-plugins.md](sources/claude-code-skills-plugins.md) | Claude Code skills + plugins |
| [sources/openai-codex-customization.md](sources/openai-codex-customization.md) | Codex AGENTS.md + skills |
| [sources/agentskills-open-standard.md](sources/agentskills-open-standard.md) | agentskills.io spec + trigger evals |
| [sources/agents-md-open-format.md](sources/agents-md-open-format.md) | AGENTS.md open format |
| [sources/anthropic-building-effective-agents.md](sources/anthropic-building-effective-agents.md) | Workflow/agent patterns |

### Tier 2 — High-quality implementations (8)

| Source file | Topic |
| --- | --- |
| [sources/anthropics-skills.md](sources/anthropics-skills.md) | Reference skills + skill-creator evals |
| [sources/swe-lego-cc-swe-review.md](sources/swe-lego-cc-swe-review.md) | Independent reconstruction review loop |
| [sources/spencermarx-open-code-review.md](sources/spencermarx-open-code-review.md) | Multi-agent phased PR review |
| [sources/mintmcp-dev-loop.md](sources/mintmcp-dev-loop.md) | Dual-model validated dev loop |
| [sources/hamelsmu-claude-review-loop.md](sources/hamelsmu-claude-review-loop.md) | Stop-hook review gate |
| [sources/calimero-ai-code-reviewer.md](sources/calimero-ai-code-reviewer.md) | Consensus + delta convergence |
| [sources/obra-superpowers.md](sources/obra-superpowers.md) | Composable methodology skills |
| [sources/microsoft-agent-framework-skills.md](sources/microsoft-agent-framework-skills.md) | Framework skills provider (spec confirmation) |

### Tier 3 — Community / ecosystem (3)

| Source file | Topic |
| --- | --- |
| [sources/voltagent-awesome-agent-skills.md](sources/voltagent-awesome-agent-skills.md) | Curated skills index + path matrix |
| [sources/dreaming-press-trigger-evals.md](sources/dreaming-press-trigger-evals.md) | Trigger eval CI framing |
| [sources/startdebugging-cursor-migration.md](sources/startdebugging-cursor-migration.md) | Rules/skills/agents sorting checklist |

---

## Findings

Organized by architectural concern (not by repository):

- [findings/skill-design.md](findings/skill-design.md)
- [findings/skill-triggering.md](findings/skill-triggering.md)
- [findings/progressive-disclosure.md](findings/progressive-disclosure.md)
- [findings/rule-design.md](findings/rule-design.md)
- [findings/agent-design.md](findings/agent-design.md)
- [findings/workflow-orchestration.md](findings/workflow-orchestration.md)
- [findings/context-engineering.md](findings/context-engineering.md)
- [findings/portability.md](findings/portability.md)
- [findings/review-loop-patterns.md](findings/review-loop-patterns.md)
- [findings/evaluation-patterns.md](findings/evaluation-patterns.md)
- [findings/failure-handling.md](findings/failure-handling.md)
- [findings/recurring-patterns.md](findings/recurring-patterns.md)
- [findings/anti-patterns.md](findings/anti-patterns.md)

---

## Comparisons

- [comparisons/skill-systems-comparison.md](comparisons/skill-systems-comparison.md)
- [comparisons/agent-systems-comparison.md](comparisons/agent-systems-comparison.md)
- [comparisons/review-loop-comparison.md](comparisons/review-loop-comparison.md)
- [comparisons/evaluation-systems-comparison.md](comparisons/evaluation-systems-comparison.md)
- [comparisons/portability.md](comparisons/portability.md)

---

## Decisions (research recommendations — not implemented)

| Decision | Outcome |
| --- | --- |
| [decision-001-skill-core.md](decisions/decision-001-skill-core.md) | **ADOPT** agentskills.io SKILL.md core |
| [decision-002-portability.md](decisions/decision-002-portability.md) | **ADOPT** portable core + thin adapters |
| [decision-003-progressive-disclosure.md](decisions/decision-003-progressive-disclosure.md) | **ADOPT** three-tier disclosure |
| [decision-004-review-loop.md](decisions/decision-004-review-loop.md) | **ADAPT** b3 loop + validation + independence |
| [decision-005-evaluation.md](decisions/decision-005-evaluation.md) | **ADAPT** trigger evals first; defer CI runner |

## Rejected

- [rejected/reject-platform-fork-core.md](rejected/reject-platform-fork-core.md)
- [rejected/reject-skill-aggregator-import.md](rejected/reject-skill-aggregator-import.md)
- [rejected/reject-monolithic-engineering-skill.md](rejected/reject-monolithic-engineering-skill.md)
- [rejected/reject-auto-lesson-to-rule.md](rejected/reject-auto-lesson-to-rule.md)

---

## Strong consensus (multi-source)

1. **SKILL.md + folder** as portable skill unit (agentskills.io; Cursor; Claude; Codex)
2. **Progressive disclosure** (metadata → body → references/scripts)
3. **Description-driven triggering** with near-miss evals
4. **AGENTS.md** for short always-on project context; skills for procedures
5. **Rules vs skills** separation (constraints vs methods)
6. **Independent review** and **iteration caps** for review loops
7. **Portable core + adapters** — same content, different discovery/hooks

See [findings/recurring-patterns.md](findings/recurring-patterns.md).

---

## Disagreements / trade-offs

| Topic | Approaches |
| --- | --- |
| Description tone | "Pushy" descriptions (skill-creator) vs strict near-miss eval discipline |
| Review architecture | SWE-Review single reconstructor vs calimero multi-agent consensus vs OCR discourse |
| Enforcement | Hooks/SessionStart (Superpowers, dev-loop) vs soft workflow (spec + skills) |
| Review depth | 8-phase OCR vs 3-step SWE-Review vs single hook pass |
| CLAUDE.md vs AGENTS.md | Native split vs symlink/`@import` bridge |

---

## Recommended direction for b3-ai-engineering

1. **Keep** current portable core layout — research validates it.
2. **Do not** import skill aggregators or duplicate per-host skill trees.
3. **Next synthesis phase:** apply decisions 001–005 into portable core docs/skills/rules (separate phase).
4. **First eval work:** trigger fixtures for four foundation skills; review-loop false-PASS scenarios.
5. **Review-loop runtime v1:** independence + finding validation + cap + stagnation — not full OCR pipeline.
6. **Adapters:** document path matrix (from VoltAgent table + official docs); optional symlinks/generators later.

---

## Deferred decisions / unknowns

| Item | Why deferred |
| --- | --- |
| Default max review-loop iterations | Field uses 3–4; needs tuning on real tasks |
| Independent reconstruction always-on | High cost; optional for critical changes only |
| Consensus scoring (calimero-style) | Useful for PR bots; may be overkill for personal loop |
| Automated eval runner / CI | Methodology clear; tooling effort deferred (decision-005) |
| Hook-based mandatory gates | Portable core cannot depend on hooks; adapter optional layer |
| AAIF AGENTS.md schema evolution | Site mentions Linux Foundation stewardship; no strict schema yet |
| Codex skills doc depth | Pointer-only in openai/codex repo at time of research |

---

## Next research phase (Phase 2 suggestion)

Target **domain synthesis** with provenance (still research → decisions before bulk skills):

1. **Frontend:** React/TypeScript/Next.js skills — official docs + 2–3 quality OSS skill examples (not aggregators)
2. **Backend/API:** REST/auth/validation patterns — official + Trail of Bits / similar security review skills
3. **Testing & TDD:** Superpowers TDD skill vs minimal portable testing-strategy skill
4. **Adapter generators:** symlink vs copy matrix tested on Cursor/Codex/Claude in a scratch repo
5. **Review-loop runtime:** deep-dive 2–3 more academic/industrial loop papers + implement fixture scenarios

---

## Store indexes

- [sources/README.md](sources/README.md)
- [findings/README.md](findings/README.md)
- [comparisons/README.md](comparisons/README.md)
- [decisions/README.md](decisions/README.md)
- [rejected/README.md](rejected/README.md)

Research date: **2026-09-07**. External docs and repositories inspected via official URLs and GitHub raw/API where noted in each source file.
