# B3 full-system review and improvement plan

**Date:** 2026-09-08  
**Scope:** git repository `b3-ai-engineering` as inspected on `main` (and this workspace).  
**Kind:** whole-system review. Not a PR review. No implementation code was changed except this document.

**Claim labels used throughout**

| Label | Meaning |
| --- | --- |
| **FACT** | Directly observed in files, tests, git, or a command run during this review |
| **INFERENCE** | Conclusion derived from that evidence |
| **RECOMMENDATION** | Proposed future change; not present behavior |

**Verification of this review**

| Check | Result |
| --- | --- |
| `find` for `Cargo.toml`, `package.json`, `*.rs`, `*.go`, `*.py`, `*.ts`, `*.js` | **FACT:** zero matches |
| File types excluding `.git` | **FACT:** Markdown, YAML, 5 `.mdc`, 2 `.sh`, LICENSE, `.gitignore` |
| `./scripts/validate-evals.sh` | **FACT:** `validated 169 fixture(s)` / `ok` (schema keys only) |
| Skill / command / agent / rule counts | **FACT:** 23 `SKILL.md`, 6 commands, 4 agents, 5 rule bodies |

Host slash-command UX, subagent auto-delegation, Codex, and Claude Code were **not** re-run here → those remain **UNKNOWN / INCOMPLETE** per `research/validation/cursor-host-v3.md` and `portability-results.md`.

---

## 1. Executive summary

**FACT:** This repository is a **portable AI engineering operating layer**: rules, Agent Skills, Cursor commands/subagents, a review-loop *procedure*, eval *fixtures*, and research provenance. Human entry: [`README.md`](../../README.md). Taxonomy: [`docs/architecture.md`](../architecture.md).

**FACT:** It is **not** a local repository-memory, indexer, MCP server, CLI, search engine, Git intelligence service, or language-server wrapper. There are no crates/packages, no `src/`, no MCP tool implementations, no on-disk code index.

The review prompt states a product vision:

> B3 is the trusted local repository-memory/context layer for coding agents.

**FACT:** That sentence does **not** appear in this repository’s README, `docs/architecture.md`, or `AGENTS.md`. The in-repo identity is: *personal AI-assisted software engineering system; Cursor first; portable meaning*.

**INFERENCE:** Two different “B3” concepts are in play:

1. **B3-as-method-OS** (this git tree) — how agents should work: constraints, methods, honest verification, independent review.
2. **B3-as-repo-memory** (stated in this review request) — what agents should *know* about a product codebase: relevance, change, next inspect, freshness/completeness.

They can compose. They must not be silently merged. Folding an indexer/MCP into this Markdown/YAML repo would violate the in-repo rule against unjustified layers ([`rules/simplest-correct.md`](../../rules/simplest-correct.md), [`docs/precedence.md`](../precedence.md) item 3: product repo requirements vs this system’s taste).

**Highest-value sequence**

1. **Decide identity in writing** (this repo vs a separate memory product) — until that is explicit, every “add indexing” or “add MCP tools” task is scope-unsafe.
2. **If keeping this repo as method-OS:** close the honesty loop (use on a real product PR; promote knowledge; cheap eval judge; Cursor UX proof). Do **not** grow the skill catalog.
3. **If building repo-memory:** greenfield a **separate** local tool (index + bounded context + freshness signals + thin MCP). This repo stays the agent playbook that *calls* it. Do not rewrite this tree into an IDE, RAG cloud, or coding agent.

**Central answer**

> Today B3 *in this repository* is a high-quality **instruction and evaluation corpus** for coding agents. It does not implement trusted repository memory. Next: either deepen this OS where it is already strong (activation honesty, review-loop exercise, knowledge), or start a **different** codebase for memory/context — not both in one pile.

---

## 2. Current system reality

### 2.1 In-repo product vision (source of truth *in git*)

**FACT:** [`README.md`](../../README.md):

- Name: `b3-ai-engineering`
- Purpose: personal, evolving operating layer for AI coding agents
- Not a company handbook
- Cursor first; Codex/Claude via adapters later
- Loop: Rules → Skills → Commands → Agents → Verification / review-loop → Lessons → Knowledge

**FACT:** [`docs/architecture.md`](../architecture.md) defines types (rule, skill, command, agent, workflow, review loop, knowledge, research, profile, adapter, eval). It does not define an index, graph, MCP server, or context pack.

**FACT:** [`AGENTS.md`](../../AGENTS.md) is the always-on map: load smallest skill; do not claim unimplemented layers exist.

### 2.2 Vision supplied by this review request

**FACT (this request, not a repo file):** B3 should help agents know what is relevant, what changed, what to inspect next, and whether repository knowledge is current and complete; participate in Plan / Understand / Implement / Review / Validate / Maintain / Onboard; must not become an IDE, autonomous agent, PM tool, CI/CD, deploy system, Git replacement, or generic cloud RAG.

**INFERENCE:** That vision describes a **local context service**. This git tree describes a **method service**. Overlap is only at the agent-facing “help the model work on a repo” slogan.

### 2.3 What actually exists (inventory of the tree)

| Area asked | Reality (**FACT**) |
| --- | --- |
| Binaries / crates / packages | None |
| Major modules | Directory taxonomy only: `rules/`, `.cursor/skills/`, `.cursor/commands/`, `.cursor/agents/`, `review-loop/`, `workflows/`, `evals/`, `research/`, `knowledge/`, `adapters/`, `docs/`, `scripts/` |
| MCP layer | None in-repo. `rules/portability.md` says MCP metadata belongs in host adapters, not portable meaning |
| Storage / indexing | None. No SQLite, no embeddings, no file watcher |
| Search / context packs | None. Agents use host tools (`Grep`, `Read`, etc.) |
| Git functionality | Normal `.git` for *this* repo; no B3 Git API |
| Symbolic / code intelligence | None (no tree-sitter, LSP client, SCIP) |
| Configuration | No app config. Cursor `.mdc` frontmatter (`alwaysApply`) on five rules |
| CLI / setup | Two bash scripts: [`scripts/validate-evals.sh`](../../scripts/validate-evals.sh), [`adapters/sync-skills.sh`](../../adapters/sync-skills.sh). Clone + open in Cursor is the “install” |
| Agent integration | Cursor discovery paths (decision-009). Codex/Claude: docs + optional symlink |
| Skills / rules / commands | 23 skills, 5 hard/strong rules, 6 slash commands, 4 subagent roles |
| Tests | 169 YAML eval fixtures + schema grep script. No unit/integration/e2e of a runtime |
| Benchmarks / dogfood | Tabletop matrix [`research/validation/validation-matrix.md`](../../research/validation/validation-matrix.md). No product-repo dogfood harness |
| Documentation | Dense and generally aligned after recent layout work; some validation notes still predate `review-loop/strategy.md` (e.g. `portability-results.md` “runtime absent”) |
| Experimental / dead | `profiles/` specified not created. `knowledge/stable` and `volatile` omitted until first entry. No committed `.agents/` / `.claude/` trees. `evals/agents/` README only |

### 2.4 How it is invoked

**FACT:**

- Always-on: `AGENTS.md` + `.cursor/rules/*.mdc` → `@rules/*.md`
- On-demand: skill `description` frontmatter; commands under `.cursor/commands/`
- Review isolation: `.cursor/agents/*.md` when the host dispatches subagents
- Other hosts: `./adapters/sync-skills.sh codex|claude`

**FACT:** Runtime injection of rules, `/plan` palette, and subagent auto-delegation are documented as **INTENDED / NOT VERIFIED** in [`research/validation/cursor-host-v3.md`](../../research/validation/cursor-host-v3.md).

**INFERENCE:** Production-readiness of *behavior* is “Markdown the host may load,” not “a service with SLOs.” Experimental vs production is the wrong dichotomy; **present vs unspecified vs deferred** (architecture language) is accurate.

### 2.5 Overlap / duplication

**FACT:** `simplest-correct` exists as both [`rules/simplest-correct.md`](../../rules/simplest-correct.md) (strong guideline) and [`.cursor/skills/architecture/simplest-correct/SKILL.md`](../../.cursor/skills/architecture/simplest-correct/SKILL.md) (method). The rule points at the skill.

**INFERENCE:** That split is intentional (constraint vs method), not accidental duplication — if agents treat them as two policies, they will collide with local “shortest code” (`engineering-principles`).

**FACT:** `code-review` skill vs `/review` vs `/review-loop` vs `reviewer` agent — documented as one pass vs loop vs isolated role ([`.cursor/commands/README.md`](../../.cursor/commands/README.md), [`review-loop/README.md`](../../review-loop/README.md)).

---

## 3. Architecture assessment

### 3.1 Actual architecture (reconstructed)

```text
                    knowledge/  (almost empty)
                         │
 rules/*.md  ──────────►  .cursor/skills/**/SKILL.md
      ▲                         │
      │                    commands / workflows
 .cursor/rules/*.mdc            │
      │                    .cursor/agents/*
      │                         │
      └──────── AGENTS.md ──────┤
                                ▼
                     review-loop/*.md  (procedure)
                                │
                     evals/*.yaml  (fixtures, no runner)
                                │
                     research/  (provenance, not runtime)
```

**Dependencies:** skills cite rules and each other by name. Commands select skills. Review-loop strategy selects agents + verification skill. Adapters do not fork meaning ([`adapters/README.md`](../../adapters/README.md)).

**Data flow:** none persisted except optional gitignored `review-loop/state/current.yaml`.

**Control flow:** human/agent reads Markdown; host may inject rules and offer `/` commands.

**Persistence boundary:** git of this repo. No index DB.

**MCP / CLI boundaries:** absent as product surfaces. Scripts are maintainer tools.

**Agent-facing interface:** skill descriptions + `AGENTS.md` + commands. That *is* the API.

**Extension points:** add a skill (with 2/2/2 evals), a rule (rare), a command, an agent role, a research decision.

### 3.2 Consistency with the two visions

| Vision | Fit |
| --- | --- |
| In-repo method-OS | **FACT:** architecture matches `docs/architecture.md` |
| Repo-memory / MCP | **FACT:** no components exist; **INFERENCE:** inconsistent until a second system exists |

### 3.3 Coupling, ownership, complexity

**FACT:** Taxonomy is strict (knowledge ≠ research ≠ reference ≠ profile). Enforcement is prose, not compiler.

**INFERENCE:** Coupling is *conceptual* (agents must load the right file). There is no hidden global process state.

**INFERENCE:** Accidental complexity is mostly **doc drift** (validation files saying review-loop runtime does not exist while [`review-loop/strategy.md`](../../review-loop/strategy.md) does) and **eval volume without a judge** (169 YAML files, grep-for-keys only).

**RECOMMENDATION:** Do not introduce Hexagonal/CQRS/event-bus shape. Named requirement for extra layers is missing. Keep one Markdown corpus + optional *separate* memory binary later.

**Unclear contracts:** host “did the skill auto-activate?” is untested. Eval fixtures have `expected_bucket` but no automated comparison to `description`.

**Error handling:** verification rule forbids fake PASS ([`rules/verification.md`](../../rules/verification.md)). There is no runtime to panic.

**Testability:** fixtures are easy to add; capability of following a skill is not automatically tested.

**Components without product purpose (vs memory vision):** the entire skill catalog is purpose-built for method-OS, **not** for indexing. Versus method-OS vision, nothing is orphaned except empty “specified” slots (`profiles/`).

---

## 4. Feature inventory

Classify vs **this repo’s** purpose. Memory-vision features that do not exist are listed as **ABSENT** (not REMOVE).

| Capability | Where | Access | Maturity | Vision (method-OS) | Vision (memory) | Class |
| --- | --- | --- | --- | --- | --- | --- |
| Hard/strong rules | `rules/`, `.cursor/rules/*.mdc` | always-on (intended) | Present; host inject **NOT VERIFIED** | Direct | Indirect (honesty) | **KEEP** |
| Engineering skills (8) | `.cursor/skills/engineering/` | description / `/skill` | Present; activation tabletop v2 | Direct | Indirect | **KEEP** |
| Domain skills (15) | frontend/backend/threejs/architecture | same | Present; no capability evals | Direct for those stacks | None | **KEEP** (do not grow) |
| Commands plan/implement/debug/review/verify/review-loop | `.cursor/commands/` | slash (intended) | Thin; UX **NOT VERIFIED** | Direct | None | **KEEP** / **IMPROVE** (verify UX) |
| Subagents reviewer/fixer/security/architecture | `.cursor/agents/` | host dispatch **NOT VERIFIED** | Thin mandates | Direct | None | **KEEP** |
| Feature workflow | `workflows/feature-implementation.md` | via `/implement` | Present | Direct | None | **KEEP** |
| Review-loop spec+strategy | `review-loop/` | `/review-loop` | Procedure present; product-PR **NOT VERIFIED** | Direct | None | **IMPROVE** (exercise) |
| Knowledge store | `knowledge/personal/engineering-context.md` only | agent read | Minimal | Direct but empty loop | Confused with “repo memory” | **IMPROVE** |
| Research provenance | `research/` | human/agent | Present | Direct | None | **KEEP** |
| Eval fixtures | `evals/` | `validate-evals.sh` | Schema-only | Direct | None | **IMPROVE** (judge) |
| Adapters | `adapters/` | `sync-skills.sh` | Intended, unverified | Direct | None | **KEEP** (don’t commit forks) |
| Profiles | not created | — | Specified | Taste | None | **KEEP absent** until owner writes |
| MCP tools | — | — | Absent | Out of scope here | Core of other vision | **ABSENT** — do not add here without identity decision |
| Index / freshness / graph | — | — | Absent | Out of scope | Core | **ABSENT** same |
| CLI `b3 setup/index` | — | — | Absent | Clone is enough | Core | **ABSENT** same |

**Do not remove** skills or the review loop because they are unused by a memory product. They are the product of *this* repo.

**UNCERTAIN:** whether `research-engineering-patterns` earns its keep (scorecard: `NOT_ENOUGH_EVIDENCE` in [`research/validation/scorecard.md`](../../research/validation/scorecard.md)). **KEEP** until a second research intake.

---

## 5. Agent workflow assessment

Hosts considered: Cursor (first), Claude Code, Codex (`adapters/*`). MCP-compatible agents: **FACT:** this repo exposes no MCP server.

### Planning

**FACT:** `/plan` → planning skill. `simplest-correct` if system shape. AGENTS.md maps layout of *this* system, not of an arbitrary product repo.

**Gap vs memory vision:** no “affected modules / entry points / impact” tool. Agents `Glob`/`Grep` the target product.

**Gap vs method-OS:** planning works *if* the agent loads the skill. Host auto-activation **NOT VERIFIED**.

### Understanding

**FACT:** No bounded context pack. Progressive disclosure is for *skills* (`SKILL.md` → `references/`), not for product source.

**INFERENCE:** Agents still pay search/read loops on product code. This repo reduces *method* search (which skill), not *code* search.

### Implementation

**FACT:** `/implement` → problem-solving + smallest domain skill. Domain skills are checklists, not symbol graphs.

### Review

**FACT:** Review-loop dimensions include architecture, correctness, security, performance, tests, maintainability ([`review-loop/spec.md`](../../review-loop/spec.md)). Impact is inferred by the reviewer reading the diff, not by a dependency graph.

### Validation (freshness / coverage / uncertainty)

**FACT:** Verification skill requires naming evidence and labeling UNKNOWN / INCOMPLETE. That is **claim** honesty, not **index** honesty.

**FACT:** No “index stale / scope incomplete” signal exists because there is no index.

**INFERENCE:** An agent can “trust B3” for *how to behave* if it follows rules; it cannot trust B3 for *what the product repo contains*.

### Maintenance (branches, sessions, teammates, agents)

**FACT:** Meaning lives in git. Skills survive sessions. No branch-aware index. Teammates cloning this repo get the same OS. Different hosts: Codex/Claude **NOT VERIFIED**.

### Onboarding

**FACT:** [`README.md`](../../README.md) + [`AGENTS.md`](../../AGENTS.md) onboard an agent to *this* system. They do not onboard to a random product codebase.

### Workflow gaps (summary)

| Workflow | Method-OS | Memory vision |
| --- | --- | --- |
| Plan | Skills exist | No repo map / impact |
| Understand | N/A | No bounded pack |
| Implement | Domain methods | No symbol retrieve |
| Review | Loop procedure | No related-code graph |
| Validate | Honest PASS/FAIL | No freshness |
| Maintain | Git of playbook | No incremental index |
| Onboard | README/AGENTS | No “important parts of *your* app” |

---

## 6. Context / memory assessment

**FACT:** There is no indexing model, incremental update, ignore-file handling for a *target* repo, context packing, or uncertainty about *indexed scope*.

What exists that looks like “memory”:

| Store | Role | Freshness |
| --- | --- | --- |
| `knowledge/` | Canonical reusable knowledge of **this** system | One personal file, `verified: false` |
| `research/` | Provenance | Dated 2026-09-07 intake |
| Skill `references/` | Task aids | Static |
| `review-loop/state/current.yaml` | Optional session log | Gitignored |

**Can an agent safely trust B3’s answer?**

- **Method questions** (“may I claim tests passed?”): **INFERENCE:** yes *if* the verification rule is injected. Host injection **NOT VERIFIED**.
- **Product-repo questions** (“what files are affected?”): **FACT:** B3 does not answer; host tools do. Trust B3 here is a category error.

**Smallest useful evidence:** this is already a written principle for skills and review findings. It is **not** implemented as a packer.

**RECOMMENDATION:** If memory-B3 is built, expose: indexed commit/branch, include/exclude globs, last successful index time, coverage %, and explicit `INCOMPLETE` when the query is outside scope. Do not imply completeness by returning a pretty snippet.

---

## 7. MCP / agent interface assessment

**FACT:** Zero first-party MCP tools in this repository.

**FACT:** Cursor Cloud sessions may have *host* MCP (`cursor-cloud`, etc.). That is not B3.

Portable rule: MCP is host-only residue ([`rules/portability.md`](../../rules/portability.md)).

### If memory-B3 is built later (RECOMMENDATION only)

Prefer a **small** contract, not internals:

| Tool (proposed name) | Purpose |
| --- | --- |
| `b3_status` | Freshness, branch, scope, last error |
| `b3_context` | Bounded pack for a question + evidence pointers |
| `b3_related` | Files/symbols related to a path or diff |
| `b3_change` | What changed vs a git ref (delegate git; add impact) |

Do **not** expose: raw DB, embedder, file walker knobs, “search_v3_debug.”

Merge/hide: duplicate search vs `rg`; duplicate outline vs LSP.

This section is **not** a commitment to implement those tools in *this* git tree.

---

## 8. CLI / setup / DX assessment

**FACT:** First run is: clone → open in Cursor → hope discovery works.

There is no `setup` → `initialize` → `index` → `configure client` → `install agent guidance` → `verify` → `first context` flow. `AGENTS.md` *is* the agent guidance. There is nothing to index.

**Friction:** undocumented knowledge includes: do not commit `.claude/skills` while using Cursor (adapter README); evals are not a test runner; `/review` ≠ `/review-loop`; `profiles/` must not be invented empty.

**Error messages:** `sync-skills.sh` warns on non-symlink dest; `validate-evals.sh` prints missing YAML keys. No product CLI errors.

**Upgrade / uninstall:** git pull / delete clone. No daemon.

**Ideal setup (method-OS) — conceptual, not implemented**

```text
clone this repo (or submodule / copy .cursor into a product)
  → open Cursor
  → confirm Skills list shows 23 B3 skills
  → /verify on a named claim
  → first useful method (e.g. /plan)
```

**Ideal setup (memory vision) — not this repo**

```text
install binary
  → b3 init (scope, ignore)
  → b3 index
  → configure MCP in Cursor/Claude/Codex
  → drop 1-page agent rule: when to call b3_status/b3_context
  → b3 doctor
  → first bounded context
```

---

## 9. Reliability assessment

**FACT:** No indexer → no stale index, no graph corruption, no interrupted index, no branch-switch index races.

**Real risks (this repo):**

| Risk | Evidence | Severity |
| --- | --- | --- |
| Agents follow stale research “next phase” | `research/validation/portability-results.md` still says review-loop runtime absent; `docs/system-lifecycle.md` on `main` still says runtime unspecified | Medium (wrong work) |
| Fake PASS in review-loop | Spec forbids it; product-PR never run | High *if* used; unproven |
| Skill greedy activation | F1–F5 retuned; only description-judge v2, not host | Medium |
| Windows symlink for adapters | Script comments junctions; **NOT VERIFIED** | Low until Codex on Windows |
| `validate-evals.sh` `grep -q "^key:"` | False confidence; no YAML parse | Low |

No panic-prone native code.

---

## 10. Testing / validation assessment

**FACT:** Application tests for *product work* are declared out of scope ([`docs/evaluation.md`](../evaluation.md)). Evals test *this* AI system.

| Kind | Present? |
| --- | --- |
| Unit tests | No |
| Integration | No |
| E2E agent | No |
| Fixtures | Yes (169 YAML) |
| Dogfood | Tabletop only |
| Benchmarks | No |
| CI | No `.github/` |
| Platform matrix | No |

`validate-evals.sh` **PASS** for schema (this review). Semantic scoring **not implemented**.

### Scenario A — First context

**Memory vision expected:** index new repo → useful bounded context.

**Current:** no index. Agent reads README/AGENTS of *this* repo or greps a product.

**Missing:** entire scenario.

### Scenario B — Branch / change context

**Expected (memory):** what is relevant after checkout/edit.

**Current:** git in the product repo; B3 silent.

### Scenario C — Stale / scoped index recovery

**Expected (memory):** explicit incomplete/stale.

**Current:** verification skill handles *claim* uncertainty, not index scope.

**Highest-value test for *this* repo:** description-judge over `evals/skills/**` + one recorded `/review-loop` on a real PR.

**Highest-value test for memory-B3:** A/B/C above against a fixture repo — only after that product exists.

---

## 11. Security / privacy assessment

Realistic threats for **this** corpus:

| Topic | FACT |
| --- | --- |
| Secrets in index | No index. `.gitignore` includes `.env` |
| MCP exposure | No B3 MCP server to bind |
| Team snapshots | N/A |
| Skills leaking employer policy | Explicitly forbidden (`engineering-principles`, knowledge context) |
| Research copies | Intake notes, not verbatim skill packs (rule: evidence-and-provenance) |
| Logs | None from B3 |

**INFERENCE:** Privacy risk of a future local indexer (secrets in `node_modules`, `.env`, generated artifacts) is **not** a current bug; it would be a **design constraint** for a memory product (honor gitignore, secret patterns, never upload).

---

## 12. Performance / token economics

**FACT:** No query latency or index benchmarks.

**INFERENCE (method-OS):** Cost is **context injection**: `AGENTS.md` + 5 always-on rules + 23 skill descriptions in the host catalog + selected `SKILL.md` (~45–73 lines) + optional references.

**FACT:** Skills are short; only four have `references/` (`nodejs-runtime`, `react-components`, `react-performance`, `testing-strategy`).

**Gains already intended:** progressive disclosure, smallest skill, commands that do not duplicate skill bodies.

**Gains not available:** reducing product-repo exploration tokens (that is memory-B3).

**RECOMMENDATION:** Measure Cursor context: are always-on rules too long? Do not add more always-on files. Do not add MCP “search everything” that dumps trees.

---

## 13. B3 boundary assessment

### What this repo should uniquely own

**RECOMMENDATION:** Portable **meaning**: verification honesty, precedence, skill methods, review-loop contract, research→knowledge promotion. Host-agnostic Markdown.

### What a memory product should uniquely own (if built)

Relevance, change impact, next-inspect, freshness/completeness over a **working tree**. Local-first. MCP or CLI as the *adapter*.

### Delegate

| Concern | Delegate to |
| --- | --- |
| Token grep | ripgrep / host `Grep` |
| Language-aware outline | LSP / nvim / IDE |
| History / blame / diff | Git |
| Apply patches | the coding agent / IDE |
| CI | product CI |
| Embeddings-only RAG | do not become generic cloud RAG (user constraint) |

### Integrate with (memory product, later)

Git for change; gitignore for scope; optional LSP for symbols; MCP for agents. This method-OS repo integrates by **telling agents when to call** memory tools (a future thin skill), not by embedding the indexer.

### Explicitly avoid (both visions)

IDE, autonomous agent, Jira, CI/CD, deploy, Git replacement, cloud RAG platform — matches the review request **and** this repo’s “not a company handbook / not unimplemented layers” stance.

### Adjacent tools (not copied)

codebase-memory-mcp, LSPs, rg, IDE indexes, agent-native explore, Git, vector RAG — **FACT:** none are dependencies of this tree. **RECOMMENDATION:** do not clone them into `b3-ai-engineering`.

---

## 14. Technical debt / risk register

Small set that actually affects the future. Not a TODO scrape.

| ID | Sev | Class | Finding | Evidence |
| --- | --- | --- | --- | --- |
| R1 | **Critical** | Product | Dual identity: memory vision vs method-OS repo | README vs this review’s stated vision; no MCP/index in tree |
| R2 | **High** | Correctness | Review-loop never proven on a product PR; host isolation unknown | `review-loop-results.md` tabletop INCOMPLETE; cursor-host-v3 |
| R3 | **High** | Agent usability | Activation unproven on host; evals cannot fail semantically | decision-005 E3 deferred; validate-evals grep-only |
| R4 | **Medium** | Maintainability | Stale validation/lifecycle sentences on `main` steer agents | `docs/system-lifecycle.md` “runtime unspecified”; `portability-results.md` “runtime absent” vs `review-loop/strategy.md` |
| R5 | **Medium** | Architecture | Knowledge loop never fires | only `engineering-context.md` |
| R6 | **Low** | DX | Codex/Claude unverified; no CI | adapters README; no `.github/` |

Style nits, extra reviewer roles, and catalog growth are **not** registered.

---

## 15. Target architecture

Do **not** redesign from scratch. Do **not** fashion a microservice memory mesh inside this repo.

### Keep (this repository)

- `rules/` + `.cursor/rules/*.mdc`
- `.cursor/skills` (23), commands, agents
- `review-loop/` procedure
- `evals/` fixtures + schema script
- `research/` provenance
- Thin adapters, no committed fork trees
- Precedence and verification honesty

### Evolve (this repository)

- Status docs so agents do not revive finished phases (partially addressed on branch `cursor/docs-lifecycle-status-42c6` / PR #8; **FACT:** `main` still has lifecycle “unspecified”)
- Description-judge for evals
- One real `/review-loop` evidence pack
- Knowledge entries from real work
- Cursor UX checklist → `research/validation/cursor-host-v4.md`

### Remove

**None** of the existing skills/commands. No evidence they are harmful.

**Do not add** placeholder `profiles/`, empty `knowledge/stable`, or MCP stubs “for symmetry.”

### Add (only if identity says so)

| If B3 remains method-OS | If B3-the-name is memory |
| --- | --- |
| Optional skill: “when the product has a context server, call it; if status is stale, say INCOMPLETE” | Separate repo: indexer + `b3_status` / `b3_context` + gitignore + doctor CLI |
| Cheap eval judge | Fixture repos for scenarios A–C |

**Target shape (composed, one developer):**

```text
[Product working tree]
        │
        ├── Git / rg / LSP (delegate)
        │
        └── optional local memory tool (MCP)     ← only if you build it
                    │
[Cursor / Claude / Codex]
        │
        └── this repo: AGENTS.md, rules, skills, review-loop
```

One deploy unit per system. No shared database. Memory tool must fail **closed** (incomplete), matching this repo’s verification rule.

---

## 16. Prioritized roadmap

Effort is described as slice size, not calendar time.

```text
0 Identity
    ↓
Foundation (docs honesty, eval judge)
    ↓
Reliability (review-loop on a real PR)
    ↓
Agent context (knowledge lessons; optional memory skill later)
    ↓
Workflow / DX (Cursor UX; other hosts when used)
    ↓
Advanced intelligence (memory product OR nothing — not more skills)
```

### 0. Identity decision

- **Goal:** One written sentence: this git repo is method-OS, memory-B3, or both-with-a-split.
- **Why:** R1. Every later item depends on it.
- **Current:** README = method-OS; this request = memory.
- **Desired:** `docs/` or README paragraph; no silent dual product.
- **Deps:** none.
- **Validation:** that paragraph exists; roadmap Track B is in or out.
- **Files:** [`README.md`](../../README.md), [`docs/architecture.md`](../architecture.md).

### Foundation — A. Finish status retarget on `main`

- **Goal:** Agents stop reading “runtime unspecified / synthesis not started.”
- **Current:** `main` lifecycle + some validation files stale; PR #8 started this.
- **Desired:** operating docs match tree; historical notes dated.
- **Deps:** 0 not blocking.
- **Validation:** `rg` for those phrases in `docs/` and `research/README.md`.
- **Files:** `docs/system-lifecycle.md`, `research/README.md`, `research/validation/portability-results.md`.

### Foundation — B. Description-judge

- **Goal:** Fixtures can fail.
- **Current:** 169 YAML; grep keys only ([`scripts/validate-evals.sh`](../../scripts/validate-evals.sh)).
- **Desired:** compare case `input` to skill `description` + expected bucket (heuristic or LLM-as-judge later).
- **Deps:** none.
- **Validation:** known v2 CORRECT cases pass; a mutated greedy description fails.
- **Files:** `evals/skills/**`, new script under `scripts/`.

### Reliability — C. Product-PR review-loop

- **Goal:** Prove independence + honest INCOMPLETE/PASS.
- **Current:** tabletop R1–R4.
- **Desired:** one recorded run with finding IDs, verify step, stop reason.
- **Deps:** a product repo (not this corpus).
- **Validation:** artifact in `research/validation/` with evidence; no fake PASS.
- **Files:** `review-loop/strategy.md`, `.cursor/commands/review-loop.md`.

### Agent context — D. Knowledge promotion

- **Goal:** Lessons → `knowledge/` with metadata.
- **Current:** stack list only.
- **Desired:** 1–3 entries from C or real work.
- **Deps:** C or any real task.
- **Validation:** entries have `source` / `last_verified`; none silently become rules.
- **Files:** [`docs/knowledge-system.md`](../knowledge-system.md), `knowledge/`.

### Workflow / DX — E. Cursor host v4

- **Goal:** Verify slash commands, rule injection, subagent dispatch.
- **Current:** v3 layout only.
- **Desired:** checklist results dated.
- **Deps:** Cursor UI.
- **Validation:** `research/validation/cursor-host-v4.md` with PASS/FAIL/INCOMPLETE per row.
- **Files:** `.cursor/commands/`, `.cursor/agents/`, `.cursor/rules/`.

### Advanced — F. Memory product (optional Track B)

- **Goal:** Local trusted context: status + bounded pack + change relevance.
- **Current:** does not exist.
- **Desired:** separate repo; MCP tools as in §7; scenarios A–C tests; honor gitignore; no cloud RAG.
- **Deps:** identity = yes; Git; ignore rules.
- **Validation:** A/B/C on a fixture repo; `b3_status` shows stale after ignored checkout without reindex.
- **Files:** **not** this tree’s `.cursor/skills` as the indexer.

Skip F entirely if identity is method-OS-only.

---

## 17. Immediate next steps

1. **Tùng records identity** (one sentence in README or a decision file). Until then, do not implement MCP/index in `b3-ai-engineering`.
2. **Land status hygiene on `main`** (PR #8 or equivalent) including leftover `portability-results.md` wording.
3. **Do not add skills.**
4. **Next implementation slice in *this* repo (if identity is method-OS):** Foundation B (description-judge) **or** Reliability C (real review-loop), not both at once.
5. **Next slice if identity is memory:** repository bootstrap for the tool (init/index/status) in a **new** repo; add a pointer from this README only.

---

## 18. Open questions / uncertainties

| ID | Question | Status |
| --- | --- | --- |
| Q1 | Is the memory vision for a different repository that just shares the name “B3”? | **UNKNOWN** — not in this git history |
| Q2 | Do B3 skills auto-activate in a fresh Cursor Agent chat? | **NOT VERIFIED** (v3). This Cloud Agent session listed 23 workspace skills in `available_skills` — **INFERENCE:** Cloud discovery can work; not a substitute for desktop UX proof |
| Q3 | Does `/review-loop` isolate reviewer vs fixer on Cursor? | **NOT VERIFIED** |
| Q4 | Default iteration cap 5 — too high/low on real PRs? | Specified, untuned |
| Q5 | Should always-on rules be reduced for token cost? | Unmeasured |
| Q6 | Will Codex/Claude be used soon enough to justify CI for `sync-skills.sh`? | Deferred by adapters README |

---

## Appendix — File map (this review)

| Path | Role |
| --- | --- |
| [`README.md`](../../README.md) | In-repo product identity |
| [`AGENTS.md`](../../AGENTS.md) | Always-on map |
| [`docs/architecture.md`](../architecture.md) | Taxonomy |
| [`docs/precedence.md`](../precedence.md) | Authority stack |
| [`rules/*.md`](../../rules/) | Constraints |
| [`.cursor/skills/`](../../.cursor/skills/) | Methods |
| [`.cursor/commands/`](../../.cursor/commands/) | User actions |
| [`.cursor/agents/`](../../.cursor/agents/) | Isolated roles |
| [`review-loop/`](../../review-loop/) | Independent review procedure |
| [`evals/`](../../evals/) | Activation/safety fixtures |
| [`research/validation/`](../../research/validation/) | Tabletop evidence |
| [`adapters/`](../../adapters/) | Other-host mapping |

End of review. Implementation code was not modified.
