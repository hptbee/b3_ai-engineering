# Decision 008 — Skill mining synthesis

## Context

Move from research into B3 artifacts. Mine curated repos; synthesize into existing architecture. Do not copy catalogs. Target stack: React, TypeScript, Node.js, C#/.NET, Three.js.

## Options Considered

1. Import Vercel / Superpowers / Microsoft / Tiki trees wholesale
2. Research-only report with no skills
3. **Selective ADAPT into B3 layers** (this decision)

## Evidence

- Decisions 001–007 (SKILL.md, portable adapters, progressive disclosure, review loop, evals, frontend/backend split)
- Sources inspected 2026-09-07: anthropics/skills, vercel-labs/agent-skills, microsoft/skills, obra/superpowers, EveryInc/compound-engineering-plugin, d-padmanabhan/agent-engineering-handbook, tikivn/agent-skills, VoltAgent/awesome-agent-skills (+ targeted three-agent-skills, EnzeD/r3f-skills)

## Decision

**ADAPT** a small domain catalog. **REJECT** bulk import.

### ADOPT (minimal change)

| Idea | From | Into |
| --- | --- | --- |
| SKILL.md + description triggers + references/ | agentskills / Anthropic skill-creator | already B3 |
| Progressive disclosure (index vs depth) | Vercel catalogs, Three.js catalogs | skill layout |
| Independent review roles | decision-004, Superpowers requesting-code-review | `agents/` |
| Explicit user commands | Superpowers / Tiki / Codex prompts | `commands/` thin files |

### ADAPT

| Idea | From | B3 change |
| --- | --- | --- |
| Systematic debugging phases | Superpowers | Drop iron-law TDD coupling; B3 verification outcomes |
| Test-first for behavior change | Superpowers TDD | Testing **strategy**, not mandatory TDD-always / delete-code |
| Bite-sized plans, no placeholders | Superpowers writing-plans | Portable `planning` skill; no Superpowers paths |
| High-impact React perf categories | Vercel react-best-practices | ~12 checks, rewritten; not 70 rules |
| Composition vs boolean props | Vercel composition-patterns | Reference inside `react-components` |
| API contract-first + boundary validation | Tiki api-and-interface-design | Merge with OWASP; ProblemDetails for .NET |
| Dispose / no alloc in loop / draw calls | emalorenzo three-best-practices **categories** | Two Three.js skills + R3F boundary; not 120 rules |
| Simplest correct > extra architecture | Tiki ponytail/karpathy; user principle | `architecture/simplest-correct` + strong rule |
| Feature loop | B3 problem-solving + Superpowers execute-plans | `workflows/feature-implementation` |

### REJECT

| Idea | Why |
| --- | --- |
| anthropics/skills document/brand/PDF packs | Off stack; not engineering methods |
| microsoft/skills Azure `*-dotnet` SDK catalog | Product APIs, not C#/ASP.NET/EF methods |
| Superpowers TDD iron law, worktrees, finishing-branch | Host/process dogma; conflicts with B3 smallest-change |
| Superpowers subagent-driven-development as default | Over-orchestration; B3 uses agents only for independent review |
| EveryInc compound plugin (multi-host forks) | Adapter anti-pattern (decision-002) |
| VoltAgent catalog import | Aggregator (already rejected) |
| tikivn duplicated `.cursor`/`.claude` copies | Forked cores |
| EnzeD 11 R3F micro-skills | Too many; one R3F integration skill |
| Generic 3d-web-experience / Spline mega-skill | Unfocused; weak evidence |
| React Native / Vercel deploy / view-transitions | Out of first-class stack |
| New hard rules for React/Three.js patterns | Volatile; belong in skills |

## Consequences

- Create focused skills under `skills/{engineering,frontend,backend,architecture,threejs}/`
- Commands/agents/workflows are thin selectors — skills hold methods
- Each new skill gets 6 eval fixtures (2/2/2)
- Foundation four skills stay; debugging/testing/planning **do not replace** them

## Confidence

Medium-High (Three.js/R3F adapted from catalog categories + official dispose practices, not a full Three.js doc pass this phase — mark version-sensitive)
