# B3 Tử Vi — Pilot Integration Contract for `/b3-research-ship`

**Status:** reference-only pilot design (`0` runtime LLM tokens in B3 core). **Do not embed Tử Vi terminology or policy into B3 core (`commands/`, `workflows/`, `scripts/`, `adapters/`).** Target pilot repo: `hptbee/b3_tuvi`.

## 1. Boundary Mapping (`b3_tuvi` → Portable B3 Contracts)

When `b3_tuvi` is attached to B3 in a future wave, it supplies **product-local configuration** under `{b3_tuvi}/.b3/` (no core B3 forks):

- `{b3_tuvi}/.b3/research-profile.md` (domain context loaded at Phase A):
  - **Research domains:** classical texts & editions, school comparisons (e.g. Nam Phái / Bắc Phái / Tam Hợp / Phi Tinh), Chính Tinh × 12 cung (`168` cells), Phụ Tinh × 12 cung (`948` cells), formations (`cách cục`), M6/M7 structural synthesis & temporal evaluation, witness & `ENGINE_CAST` controls, source/rights classification.
  - **Editorial & Release Policy (`b3-release-policy/3`, `b3.ai-reviewers/2`):**
    - Interpretive fidelity per `docs/tuvi/INTERPRETATION_EDITORIAL_POLICY.md` (Rules A–G, `OD-INTERP-01`, `OD-INTERP-02`: preserve classical meaning & polarity without topic-based sanitization).
    - AI editorial review per `docs/tuvi/RELEASE_GOVERNANCE_V2.md`:
      - `default` tier: `gemini-4-carbon-high` (primary, `carbon-high-editorial`, `OD-REV-DEFAULT-AGY-01`) or `gemini-4-hydrogen-high` (secondary).
      - `escalation` tier: `gemini-4-carbon-medium` (`carbon-medium-escalation`, `OD-REV-CARBON-01`, requires non-placeholder `escalationReason`).
      - Historical frozen Anthropic profiles (`claude-opus-5-5`, `claude-sonnet-5-5`, `claude-fable-5-1`, `claude-fable-5-2`) remain read-only for digest verification and are never spoofed or re-invoked on Antigravity.
      - Do **not** insert a mandatory human approval gate where `b3-release-policy/3` lawfully authorizes registered AI editorial review.
  - **Three-Anti Single-Writer Boundary (`docs/planning/THREE_ANTI_KNOWLEDGE_ACTIVATION.md`):**
    - Anti 1 alone integrates canonical release ledgers, generated release artifacts (`v3-release.v1.json`), shared manifests, adoption pins (`V3_DOMAIN_AUTHORITY_V2_BASE`), and `ai-reviewers.json` / authority updates.
    - Anti 2 (supporting cohorts) and Anti 3 (private engines/M6-M7/witnesses) hand off disjoint evidence packets via `handoff` records without concurrently writing shared ledgers.
  - **Unblocked Unit Continuation:** if one star/cell unit awaits an Owner decision (`OD-*`, `WITHHELD`, `AI_NO_DECISION`), mark only that unit `blocked` and proceed on independent eligible units.

- `{b3_tuvi}/.b3/research-policy.json` (deterministic gate enforced by `b3-guard merge-policy-check`):

```json
{
  "auto_merge": "disabled",
  "protected_paths": [
    "backend/src/knowledge/v3Release/",
    "backend/src/knowledge/stars/aiReleasePolicy.js",
    "docs/planning/adoption/",
    "docs/tuvi/RELEASE_GOVERNANCE_V2.md",
    "docs/tuvi/INTERPRETATION_EDITORIAL_POLICY.md"
  ],
  "allow_protected_paths": false,
  "require_ci": true,
  "require_review": true
}
```

## 2. Critical Invariants Enforced by `/b3-research-ship`

- `RESEARCHED != VERIFIED != IMPLEMENTED != RELEASED` and `PR_MERGED != RUNTIME_SERVED != DEPLOYED`.
- Research-only PRs (documentation, candidate notes, non-protected research units) may reach `PR_READY` even while publication/authority release remains blocked.
- `WITHHELD`, `AI_NO_DECISION`, missing `OD-*` Owner decisions, invalid digest-bound reviews, or unauthorized reviewer registrations map to `GovernanceStatus` != `CLEAR` (`WITHHELD_PROMOTION`, `MISSING_OWNER_DECISION`, `INVALID_EDITORIAL_REVIEW`, `UNAUTHORIZED_REVIEWER`, `UNAUTHORIZED_AUTHORITY`) → `b3-guard merge-policy-check` fails closed with `MERGE_BLOCKED` (`exit 1`).
- Never fabricate Owner decisions (`OD-*`), authority pins, `ENGINE_CAST` witness passes, or `provider: "anthropic"` claims for Google models.
- Post-merge verification (`merge-policy-check -PostMerge`) confirms PR merge + `main` ancestry + artifact reconciliation, while leaving `runtime_served` and `deployed` as `NOT_VERIFIED` until live API/serving checks (e.g., `/api/released-interpretations/v3` + deployment probes) succeed independently.
