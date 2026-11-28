# Clarification Gate & Global Planning Contract (On-Demand)

Single canonical clarification contract anchored by `rules/engineering-principles.md` (Rule 1) and inherited proportionally by all B3 commands and workflows via [`dispatch-naming.md`](dispatch-naming.md). Keep the detailed rubric here—never duplicate it across commands or skills.

## Configuration & Precedence

Reuse existing B3 preference files with zero external runtime dependencies:

- **Built-in defaults:** `clarification_gate: true`, `understanding_threshold: 96` (integer percentage `1..=100`).
- **Personal config:** `~/.b3/models.md` (or `B3_MODELS_PERSONAL` env var).
- **Project override:** `<project>/.b3/models.md`.
- **Per-invocation override:** explicit inline directive or user instruction in the current prompt (for example `clarification_gate: false`, `understanding_threshold: 90`, or "proceed with safe assumptions without asking routine questions").

Optional `planning:` YAML block inside `models.md`:

```yaml
planning:
  clarification_gate: true
  understanding_threshold: 96
```

- **Precedence:** `per-invocation override > <project>/.b3/models.md > ~/.b3/models.md (B3_MODELS_PERSONAL) > built-in defaults (true, 96)`.
- **Graceful host degradation:** Works across Cursor, Codex, Claude Code, and Antigravity. Missing, partial, or malformed preference files fall back silently to built-in defaults and never block execution or mutate host settings.

## 7-Step Global Planning Contract & Gate

Before changing non-trivial affected targets, follow this contract proportionally to task scope and risk:

1. **Core objective:** State the user's primary goal in one verifiable sentence.
2. **Explicit requirements:** Extract stated behaviors, inputs, outputs, and priorities.
3. **Constraints & non-goals:** Identify technical/policy limits and explicit out-of-scope bounds.
4. **Acceptance criteria (ACs):** Define observable, testable success conditions and verification checks.
5. **Project context:** Inspect relevant source files, docs, prior decisions, configs, tests, and conventions.
6. **Local uncertainty resolution:** Resolve answerable questions locally through discovery before asking the user.
7. **Remaining understanding assessment:** Evaluate remaining clarity across material dimensions and isolate or clarify gaps.

### Gate Rule

- **Proceed:** `understanding >= understanding_threshold` AND zero unresolved material/critical ambiguities.
- **Clarify affected work:** `understanding < understanding_threshold` → hold edits to affected targets and batch material questions for the user.
- **Critical ambiguity override:** Any unresolved critical or irreversible ambiguity blocks the affected workstream **regardless of score**—never average away critical unknowns with high scores on minor dimensions.

## 10 Understanding Assessment Dimensions

Assess clarity across these 10 dimensions when planning or scoping non-trivial work:

1. **User intent** & desired outcome
2. **Functional requirements** & key edge cases
3. **Scope & non-goals** (in-scope vs out-of-scope boundaries)
4. **Concrete deliverables** & touched files/artifacts
5. **Acceptance criteria** & verification expectations
6. **Technical & architectural constraints**
7. **Compatibility & integration boundaries** (APIs, schemas, callers, hosts)
8. **Security, authn/authz & data/privacy implications**
9. **External side effects** (PRs, remote APIs, deploys, migrations, billing/state)
10. **Irreversible or destructive decisions**

- **Evidence grounding:** Every assessment must be an honest heuristic engineering judgment grounded in inspected evidence and explicitly named uncertainties—never fabricate, pad, or inflate scores to pass the threshold.
- **Trivial-task shortcut:** Skip exhaustive 10-dimension scoring on trivial, clearly specified tasks (localized 1-file fixes or explicit mechanical requests with zero material unknowns).

## Clarification Behavior

- **Exhaust low-cost local discovery first:** Before asking the user, inspect source code, docs, prior decisions (`research/decisions/`), config files, repo conventions, acceptance tests, and architectural contracts.
- **Ask only material questions:** Only ask when the answer changes design, scope, contracts, safety, or acceptance criteria.
- **Batch independent questions:** Group all independent questions into one concise request stating for each item:
  1. what is unclear,
  2. why it matters,
  3. viable options (with tradeoffs),
  4. recommended default.
- **Never re-ask** questions already answered in the conversation, plan, or repository artifacts.
- **Never ask confirmation** for routine implementation details, reversible internal refactoring, ordinary test authoring/execution, or established repository conventions.

## Maximum Safe Parallelism Integration

Partial ambiguity must **never** stall safe independent work:

1. **Isolate only blocked workstreams:** Mark only the tasks/units depending on the unresolved decision as blocked; apply **zero speculative edits** inside blocked workstreams.
2. **Continue safe parallel/independent work** per [`dispatch-naming.md`](dispatch-naming.md):
   - independent `SHARED_READ_ONLY` discovery, research, and analysis,
   - independent authorized and sufficiently understood implementation units whose edits and side effects cannot prejudice the pending decision,
   - safe test/baseline preparation and fixture analysis.
3. **Resume smoothly after clarification:** Update understanding and the dependency graph, release newly unblocked tasks immediately, reuse valid completed investigation and warm worker context, and **never restart planning from scratch**.

## Disabled Mode (`clarification_gate: false`)

When disabled globally, per-project, or per-invocation:

- Resolve ordinary implementation ambiguities using repository conventions and reversible, low-risk assumptions.
- Document all material assumptions explicitly in the plan, `progress.md`, or delivery report.
- Minimize user interruptions.
- **Mandatory safety & governance floor (NEVER bypassed):** `clarification_gate: false` never waives security/authz boundaries, required user authorization, research governance or Owner/editorial authority gates (`research-ship.md`), `--protected-paths` or protected operations, destructive/irreversible safeguards, merge authorization (`merge-policy-check`), or external mutation permissions. Report `BLOCKED` whenever a mandatory decision cannot be safely inferred or delegated.

## Reassessment During Execution

- Do **not** re-run clarification checks on every routine step.
- Reassess **only** on a material trigger:
  - new material user requirement,
  - contradicting codebase, test, or runtime evidence,
  - significant scope change,
  - previously unknown architectural constraint,
  - ambiguous or untestable ACs uncovered during build/verify,
  - newly surfaced irreversible or security-sensitive decision.
- Invalidate **only** the affected plan slice(s) or workstream(s); preserve valid completed work, commits, and fresh verification evidence.

## Proportional System-Wide Inheritance

Inherited by all 14 commands (`b3-plan`, `b3-implement`, `b3-debug`, `b3-research`, `b3-audit`, `b3-review`, `b3-refactor`, `b3-verify`, `b3-review-loop`, `b3-ship`, `b3-research-ship`, `b3-pr-resolve`, `b3-pr-reply`, `b3-pr-comment`) and any future commands via `rules/engineering-principles.md` + [`dispatch-naming.md`](dispatch-naming.md), proportional to intent and risk:

- **Lightweight / read-only / bounded commands** (`b3-verify`, `b3-research`, `b3-audit`, `b3-review`, `b3-pr-reply`, `b3-pr-comment`, localized `b3-debug` / `b3-implement` / `b3-refactor`): apply silently—confirm target, claim, or required external authorization after local inspection; ask only on genuine material ambiguity without turning lightweight commands into heavyweight planning workflows.
- **Planning / multi-step / autonomous delivery commands** (`b3-plan`, `b3-ship`, `b3-research-ship`, complex `b3-implement` / `b3-refactor` / `b3-review-loop` / `b3-pr-resolve`): apply the full 7-step contract, evidence-grounded assessment against `understanding_threshold`, partial-ambiguity unit isolation, and execution reassessment triggers.
