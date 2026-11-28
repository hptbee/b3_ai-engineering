# Clarification Gate & Global Planning Contract (On-Demand)

Canonical clarification contract anchored by `rules/engineering-principles.md` (Rule 1), inherited proportionally via [`dispatch-naming.md`](dispatch-naming.md). Loaded **on demand** when complexity or material ambiguity warrants—never into worker briefs or routine `XS`/`S` tasks.

## Configuration & Field-Level Precedence

```yaml
planning:
  clarification_gate: true
  understanding_threshold: 96   # integer 1..=100
```

- **Defaults & precedence:** `per-invocation override > <project>/.b3/models.md > ~/.b3/models.md (B3_MODELS_PERSONAL) > built-in defaults (true, 96)`.
- **Resolve once & per-field fallback:** Parent resolves `planning:` **once per invocation** without mutating preference or host files. Missing, partial, or invalid fields/files fall back **per field to the next valid layer**, then defaults—bad project fields never drop valid personal fields, and bad config never blocks on Cursor, Codex, Claude Code, or Antigravity.

## Risk-Based Proportionality & Assessment

Pair task size (`XS` | `S` | `M` | `L` | `XL` | `XXL`) with risk (`LOW` | `MEDIUM` | `HIGH` | `CRITICAL`)—size never replaces risk (a small authz edit needs deeper review than a large refactor):

- **`XS` / `S` (clear, localized, low-risk):** Confirm intent, inspect targets, execute immediately; skip full rubric, numeric scorecards, and extra artifacts.
- **`M` / `L` (multi-file / moderate):** Define goal, requirements, constraints/non-goals, `AC1..ACn`; inspect code/docs/configs/tests/`research/decisions/`; assess relevant dimensions.
- **`XL` / `XXL` or `HIGH` / `CRITICAL` risk:** Assess shared contracts, deps, compatibility, security/authz/privacy, external side effects, irreversible choices; isolate uncertain slices and continue safe work.

**7-Step Contract:** (1) Core objective (1 sentence), (2) Explicit requirements, (3) Constraints & non-goals, (4) Testable `AC1..ACn` & verification, (5) Project context discovery, (6) Local uncertainty resolution, (7) Material ambiguity gate.

**10 Dimensions:** (1) Intent, (2) Functional reqs & edge cases, (3) Scope & non-goals, (4) Deliverables & targets, (5) ACs & verification, (6) Technical/arch constraints, (7) Compatibility & integration boundaries, (8) Security/authn/authz/privacy, (9) External side effects, (10) Irreversible/destructive choices.

## Non-Blocking Gate Behavior

Treat `understanding_threshold` (`96`) as an **evidence-grounded heuristic trigger**, not rigid math. **Never** inflate scores, and **never** block solely on score `< understanding_threshold` when zero actionable material ambiguity remains.

1. **Clear & zero material ambiguity:** Proceed autonomously; no unnecessary questions or scorecards.
2. **Understanding `< understanding_threshold`:** Do proportional local discovery, list uncertainties, resolve routine gaps via repo conventions and reversible assumptions, and ask **only** when material ambiguity needs a user decision.
3. **Material ambiguity remains:** Hold **only** affected tasks (zero speculative edits), batch concise questions (unclear point, impact, options + tradeoffs, recommended default), and continue independent work.
4. **Critical, irreversible, security, or authz ambiguity:** Block affected work **regardless of score** (never average away critical unknowns).
5. **Disabled (`clarification_gate: false`):** Use reversible repo-consistent assumptions for routine gaps and document material assumptions. **Never** bypass security/authz, user authorization, research/Owner governance ([`../research-ship.md`](../research-ship.md)), `--protected-paths`, destructive safeguards, or `merge-policy-check` (`BLOCKED` if mandatory auth or required decision is missing or unverified).

Never re-ask answered questions or confirm routine details, tests, or conventions.

## Parent-Only Ownership & Maximum Safe Parallelism

- **Parent (sole clarification owner):** Resolves `planning:` once, assesses scope, owns user questions, merges worker uncertainties, updates plan/deps, releases unblocked tasks immediately, and reassesses only affected slices.
- **Planning / scout agents:** Inspect context, surface gaps/contradictions, return findings to Parent.
- **Implementation workers:** Execute `Context Packet`, report new material ambiguity to Parent, continue unaffected work. Workers **must NOT** load `clarification-gate.md`, re-read `models.md`, recalc percentages, ask users, or restart planning.
- **Reviewers:** Report contradictions, gaps, risks, and evidence to Parent without restarting clarification.
- **Continuous isolation (`A..F`):** If `A` needs a user decision and `B, C, D` declare `depends_on: [A]`, hold `A, B, C, D` while running independent `E` and `SHARED_READ_ONLY` `F`. Ask only `A`'s question; once clarified & verified, release eligible dependents immediately per [`dispatch-naming.md`](dispatch-naming.md) without waiting or restarting planning.

## Targeted Reassessment & Inheritance

Never re-run clarification on routine steps. Reassess **only** on material triggers (new req, contradicting evidence, major scope shift, unknown arch constraint, untestable AC, new irreversible/security choice); invalidate **only** affected slices; keep valid work and receipts.

Inherited proportionally across all 14 commands (`b3-plan`, `b3-implement`, `b3-debug`, `b3-research`, `b3-audit`, `b3-review`, `b3-refactor`, `b3-verify`, `b3-review-loop`, `b3-ship`, `b3-research-ship`, `b3-pr-resolve`, `b3-pr-reply`, `b3-pr-comment`).
