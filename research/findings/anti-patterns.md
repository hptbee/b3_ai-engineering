# Anti-patterns

Evidence-backed patterns to avoid. Each cites research sources.

---

## Monolithic "engineering everything" skill

**Observation:** Large catch-all SKILL.md packs appear in community aggregators, not in vendor reference designs.

**Evidence:** VoltAgent list scale vs anthropics/Superpowers decomposition; skill-creator warns on size (>500 lines) with reference split.

**Why harmful:** Trigger imprecision, stale content, impossible eval coverage.

**Confidence:** Medium-High

---

## Copying curated skill dumps without synthesis

**Observation:** awesome-agent-skills and similar repos optimize for quantity; official sources warn demo skills ≠ production behavior.

**Evidence:** `voltagent-awesome-agent-skills.md`, anthropics/skills disclaimer.

**Why harmful:** Platform lock-in, duplicate conflicting guidance, no provenance.

**Confidence:** High

---

## Always-on procedure text (rules/AGENTS.md bloat)

**Observation:** Codex enforces 32 KiB cap; Cursor migration guides move dynamic procedures to skills.

**Evidence:** `openai-codex-customization.md`, `startdebugging-cursor-migration.md`.

**Why harmful:** Token waste; wrong guidance loaded for unrelated tasks.

**Confidence:** High

---

## Self-review without isolation

**Observation:** SWE-Review explicitly rejects reviewer sharing patchgen context; dev-loop uses separate model/process for review.

**Evidence:** `swe-lego-cc-swe-review.md`, `mintmcp-dev-loop.md`.

**Why harmful:** Anchoring, false LGTM.

**Confidence:** High

---

## Unbounded review loops

**Observation:** Production loops implement hard caps (3–4 typical); Anthropic emphasizes stopping conditions.

**Evidence:** SWE-Review, dev-loop, `anthropic-building-effective-agents.md`.

**Why harmful:** Token/cost runaway; illusory progress.

**Confidence:** High

---

## Tool failure treated as success

**Observation:** Industry failure mode; b3 rules align with fail-closed principle echoed in verification skills (Superpowers).

**Evidence:** `failure-handling.md` finding, `obra-superpowers.md` (verification-before-completion).

**Why harmful:** False PASS in CI/production.

**Confidence:** High

---

## Speculative findings as blockers

**Observation:** calimero uses consensus; dev-loop validates against code; OCR uses discourse/dedup.

**Evidence:** `calimero-ai-code-reviewer.md`, `mintmcp-dev-loop.md`, `spencermarx-open-code-review.md`.

**Why harmful:** Noise-driven refactors; reviewer fatigue.

**Confidence:** Medium-High

---

## Over-pushy descriptions without evals

**Observation:** skill-creator and spec suggest expansive descriptions to fight under-triggering.

**Evidence:** raw skill-creator SKILL.md header; agentskills optimizing-descriptions.

**Why harmful:** Over-triggering / skill hijacking if not paired with near-miss evals.

**Confidence:** Medium

---

## Platform-forked portable core

**Observation:** Multiple discovery roots tempt duplicating SKILL.md under `.cursor/`, `.claude/`, `.codex/` separately.

**Evidence:** Cursor compatibility loading; VoltAgent path table.

**Why harmful:** Drift between copies; breaks portable-first goal.

**Confidence:** High

---

## Lessons → rules without evaluation

**Observation:** Not widely implemented in external repos (gap), but Superpowers hook/session enforcement shows risk of hardening preferences into mandatory workflow.

**Evidence:** b3 `system-lifecycle.md` (internal); Superpowers SessionStart injection (external caution).

**Why harmful:** Bad rules persist; system rigidity.

**Confidence:** Medium (conceptual; fewer external eval gates documented)

---

## Counting copied implementations as independent evidence

**Observation:** Many Claude Code review plugins share hook/subagent patterns — lineage not independent.

**Evidence:** Similar `.claude-plugin/` layouts across SWE-Review, OCR, dev-loop, claude-review-loop.

**Why harmful:** Overconfidence in pattern popularity.

**Confidence:** High
