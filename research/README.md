# Research — Agent Engineering System

Phase 1 (foundations) and **Phase 2 Tracks A/B** (domain research) are complete for this branch. **Track C** (adapters + eval fixtures) implemented outside `research/` per decision-005.

## Phase summary

| Phase | Scope | Status |
| --- | --- | --- |
| Phase 1 | Skills, rules, agents, review, eval, portability | ✓ `research/` only |
| Track A | Frontend: React, TS, Next.js, UI/a11y | ✓ research only |
| Track B | Backend: Node, API, auth, security | ✓ research only |
| Track C | Adapters + eval fixtures | ✓ `adapters/`, `evals/`, `scripts/` |
| Synthesis | Mine/adapt skills into B3 | ✓ decision-008 + `.cursor/skills/` |
| Validation v1 | Real-task matrix, activation, composition | ✓ `research/validation/` |

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
 Knowledge / Skills / Rules / Adapters  (present; see repo catalogs)
```

Rejected ideas: `research/rejected/`

---

## Sources (29)

### Phase 1 — Tier 1 official (8)

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

### Layout amendment — 2026-09 (1)

| Source file | Topic |
| --- | --- |
| [sources/cursor-docs-2026-09.md](sources/cursor-docs-2026-09.md) | Current Cursor skills, rules, subagents (decision-009) |

### Phase 1 — Tier 2 implementations (8)

| Source file | Topic |
| --- | --- |
| [sources/anthropics-skills.md](sources/anthropics-skills.md) | Reference skills + skill-creator evals |
| [sources/swe-lego-cc-swe-review.md](sources/swe-lego-cc-swe-review.md) | Independent reconstruction review loop |
| [sources/spencermarx-open-code-review.md](sources/spencermarx-open-code-review.md) | Multi-agent phased PR review |
| [sources/mintmcp-dev-loop.md](sources/mintmcp-dev-loop.md) | Dual-model validated dev loop |
| [sources/hamelsmu-claude-review-loop.md](sources/hamelsmu-claude-review-loop.md) | Stop-hook review gate |
| [sources/calimero-ai-code-reviewer.md](sources/calimero-ai-code-reviewer.md) | Consensus + delta convergence |
| [sources/obra-superpowers.md](sources/obra-superpowers.md) | Composable methodology skills |
| [sources/microsoft-agent-framework-skills.md](sources/microsoft-agent-framework-skills.md) | Framework skills provider |

### Phase 1 — Tier 3 community (3)

| Source file | Topic |
| --- | --- |
| [sources/voltagent-awesome-agent-skills.md](sources/voltagent-awesome-agent-skills.md) | Curated skills index + path matrix |
| [sources/dreaming-press-trigger-evals.md](sources/dreaming-press-trigger-evals.md) | Trigger eval CI framing |
| [sources/startdebugging-cursor-migration.md](sources/startdebugging-cursor-migration.md) | Rules/skills/agents sorting checklist |

### Track A — Frontend (5)

| Source file | Topic |
| --- | --- |
| [sources/react-dev-thinking-in-react.md](sources/react-dev-thinking-in-react.md) | React component/state method |
| [sources/nextjs-app-router.md](sources/nextjs-app-router.md) | Next.js App Router conventions |
| [sources/typescript-handbook.md](sources/typescript-handbook.md) | TypeScript handbook structure |
| [sources/vercel-react-best-practices.md](sources/vercel-react-best-practices.md) | OSS perf skill catalog pattern |
| [sources/w3c-wcag.md](sources/w3c-wcag.md) | WCAG 2.2 accessibility standard |

### Track B — Backend (4)

| Source file | Topic |
| --- | --- |
| [sources/owasp-api-security-top10.md](sources/owasp-api-security-top10.md) | OWASP API Security Top 10 2023 |
| [sources/owasp-authentication-cheat-sheet.md](sources/owasp-authentication-cheat-sheet.md) | OWASP Authentication Cheat Sheet |
| [sources/nodejs-security-best-practices.md](sources/nodejs-security-best-practices.md) | Node.js application security |
| [sources/trailofbits-differential-review.md](sources/trailofbits-differential-review.md) | Security differential review skill |

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

### Track A — Frontend

- [findings/frontend-react.md](findings/frontend-react.md)
- [findings/frontend-nextjs.md](findings/frontend-nextjs.md)
- [findings/frontend-ui-accessibility.md](findings/frontend-ui-accessibility.md)

### Track B — Backend

- [findings/backend-api-design.md](findings/backend-api-design.md)
- [findings/backend-auth-security.md](findings/backend-auth-security.md)
- [findings/backend-node-architecture.md](findings/backend-node-architecture.md)

---

## Comparisons

- [comparisons/skill-systems-comparison.md](comparisons/skill-systems-comparison.md)
- [comparisons/agent-systems-comparison.md](comparisons/agent-systems-comparison.md)
- [comparisons/review-loop-comparison.md](comparisons/review-loop-comparison.md)
- [comparisons/evaluation-systems-comparison.md](comparisons/evaluation-systems-comparison.md)
- [comparisons/portability.md](comparisons/portability.md)
- [comparisons/frontend-skills-comparison.md](comparisons/frontend-skills-comparison.md)
- [comparisons/backend-skills-comparison.md](comparisons/backend-skills-comparison.md)

---

## Decisions (research recommendations)

| Decision | Outcome |
| --- | --- |
| [decision-001-skill-core.md](decisions/decision-001-skill-core.md) | **ADOPT** agentskills.io SKILL.md core |
| [decision-002-portability.md](decisions/decision-002-portability.md) | **ADOPT** portable core + thin adapters |
| [decision-003-progressive-disclosure.md](decisions/decision-003-progressive-disclosure.md) | **ADOPT** three-tier disclosure |
| [decision-004-review-loop.md](decisions/decision-004-review-loop.md) | **ADAPT** b3 loop + validation + independence |
| [decision-005-evaluation.md](decisions/decision-005-evaluation.md) | **ADAPT** trigger evals first; defer CI runner |
| [decision-006-frontend-skills.md](decisions/decision-006-frontend-skills.md) | **ADAPT** split frontend skills; reject Vercel bulk copy |
| [decision-007-backend-skills.md](decisions/decision-007-backend-skills.md) | **ADAPT** layered backend security skills |
| [decision-008-skill-synthesis.md](decisions/decision-008-skill-synthesis.md) | **ADAPT** mined skills into B3; reject catalogs |
| [decision-009-cursor-native-layout.md](decisions/decision-009-cursor-native-layout.md) | **ADAPT** Cursor-native discovery paths; portable meaning (amends 002 location) |

## Rejected

- [rejected/reject-platform-fork-core.md](rejected/reject-platform-fork-core.md)
- [rejected/reject-skill-aggregator-import.md](rejected/reject-skill-aggregator-import.md)
- [rejected/reject-monolithic-engineering-skill.md](rejected/reject-monolithic-engineering-skill.md)
- [rejected/reject-auto-lesson-to-rule.md](rejected/reject-auto-lesson-to-rule.md)
- [rejected/reject-tdd-iron-law-default.md](rejected/reject-tdd-iron-law-default.md)
- [rejected/reject-microsoft-azure-sdk-catalog.md](rejected/reject-microsoft-azure-sdk-catalog.md)

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

Status as of the catalog after decision-008/009 (do not re-run synthesis as if it never happened):

1. **Keep** the portable core and Cursor-native discovery paths — research validates them.
2. **Do not** import skill aggregators or commit duplicate Codex/Claude skill trees here.
3. **Domain skills** from decisions 006–007 are **present** (see `.cursor/skills/README.md`) with trigger fixtures. Do not grow the catalog until real-task lessons or capability evals exist.
4. **Eval work:** E1+E2 fixtures shipped; schema check `scripts/validate-evals.sh`. E3 automated runner and E4 capability benchmarks remain **deferred** (decision-005).
5. **Review-loop orchestration v1 is present** (`review-loop/strategy.md`): independence, finding validation, cap, stagnation. Not a host plugin and not a full OCR pipeline. Product-repo runs and subagent isolation remain **NOT VERIFIED**.
6. **Adapters:** path matrix + `sync-skills.sh`. Cursor `.mdc` activation files are **present** (five files under `.cursor/rules/`). Codex/Claude export and adapter CI remain deferred.

---

## Deferred decisions / unknowns

| Item | Status |
| --- | --- |
| Default max review-loop iterations | **Specified** as 5 for SMALL/MEDIUM (`review-loop/strategy.md`); still tunable after real product PRs |
| Independent reconstruction always-on | Deferred — high cost; optional for critical changes only |
| Consensus scoring (calimero-style) | Deferred — useful for PR bots; may be overkill for a personal loop |
| Automated eval runner / CI | Deferred (decision-005 E3) |
| Hook-based mandatory gates | Deferred — portable core cannot depend on hooks; adapter optional layer |
| AAIF AGENTS.md schema evolution | Unchanged — no strict schema at research time |
| Codex skills doc depth | Unchanged — pointer-only in openai/codex at research time |
| Frontend/backend domain skills | **Done** — synthesized (decision-008); do not treat as unstarted |
| Cursor `.mdc` rule activation | **Done** — `.cursor/rules/*.mdc` `@`-include `rules/*.md` (decision-009) |
| OAuth/OIDC implementation depth | Deferred — cheat sheet covered; spec deep-dive not a skill yet |
| Knowledge promotion / `profiles/` | Deferred until real lessons and owner-recorded taste exist |

---

## Next (after synthesis and layout)

1. **Use the system on a real product change**; promote 1–3 lessons into `knowledge/` (do not scrape `stable/`).
2. **Exercise `/review-loop` on a product PR**; record host isolation (reviewer vs fixer) under `research/validation/`.
3. **Cursor UX check** (slash commands, rule injection, subagent dispatch) — still **NOT VERIFIED** in-repo (`cursor-host-v3.md`).
4. **Eval hygiene:** remaining rule fixtures (`engineering-principles`, `portability`); optional description-judge. E3 runner still deferred.
5. **Capability evals** and extra reviewer agents — only after repeated real-task evidence.
6. **Owner profile** when Tùng records it (`profiles/` is not invented for symmetry).

## Track C deliverables (outside research/)

| Artifact | Location |
| --- | --- |
| Host path matrix | `adapters/README.md` |
| Per-host mapping | `adapters/{cursor,codex,claude}/README.md` |
| Skill symlink script | `adapters/sync-skills.sh` |
| Skill trigger fixtures | `evals/skills/**` (148 YAML cases as of this status pass) |
| Review-loop scenarios | `evals/review-loop/**` (15 YAML cases) |
| Rule samples | `evals/rules/**` (6 YAML cases) |
| Fixture validator | `scripts/validate-evals.sh` |

---

## Store indexes

- [sources/README.md](sources/README.md)
- [findings/README.md](findings/README.md)
- [comparisons/README.md](comparisons/README.md)
- [decisions/README.md](decisions/README.md)
- [rejected/README.md](rejected/README.md)
- [validation/README.md](validation/README.md)

Research date: **2026-09-07**. External docs and repositories inspected via official URLs and GitHub raw/API where noted in each source file. Status retarget vs the current tree: **2026-09-08** (does not re-date source intake).
