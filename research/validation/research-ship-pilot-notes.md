# Historical Pilot Validation Notes — Domain Integration Boundary for `/b3-research-ship`

> **Status:** Historical pilot validation & boundary-mapping provenance (`0` runtime LLM tokens in B3 core). Relocated from `docs/research-ship-tuvi-pilot.md` and sanitized to generic `<model-id>` placeholders (`CF-12`). Canonical `/b3-research-ship` contracts live in [`../../workflows/research-ship.md`](../../workflows/research-ship.md) and [`../../scripts/README.md`](../../scripts/README.md). **Do not embed domain-specific terminology, product paths, or vendor model IDs into B3 core (`commands/`, `workflows/`, `scripts/`, `adapters/`, `docs/`).**

## 1. Historical Boundary Mapping (External Pilot Product → Portable B3 Contracts)

During `/b3-research-ship` design validation against an external classical-knowledge product repository (`b3_tuvi`), product-specific configuration was isolated strictly under `<product>/.b3/` (zero core B3 forks):

- `<product>/.b3/research-profile.md` (domain context loaded on demand at Phase A):
  - **Research domains:** classical texts & editions, multi-school comparisons, domain-unit matrices, structural synthesis & temporal evaluation, deterministic engine/witness controls, and source/rights classification.
  - **Editorial & Release Policy (`b3-release-policy/3`, `b3.ai-reviewers/2`):**
    - Interpretive fidelity per product-local editorial policy (`OD-INTERP-01`, `OD-INTERP-02`: preserve source meaning & polarity without topic-based sanitization).
    - AI editorial review per product-local release governance:
      - `default` tier: `<model-id>` (primary `<editorial-primary-profile>`, `OD-REV-DEFAULT-01`) or `<model-id>` (secondary `<editorial-secondary-profile>`).
      - `escalation` tier: `<model-id>` (`<editorial-escalation-profile>`, `OD-REV-ESCALATION-01`, requires non-placeholder `escalationReason`).
      - Historical frozen reviewer profiles (`<model-id>`, `<model-id>`) remain read-only for historical digest verification and are never spoofed or re-invoked across incompatible host providers.
      - Do **not** insert a mandatory human approval gate where product policy lawfully authorizes registered editorial review.
  - **Single-Writer Boundary:**
    - One designated integrator alone updates canonical release ledgers, generated release artifacts, shared manifests, adoption pins, and reviewer/authority registries.
    - Supporting workers hand off disjoint evidence packets without concurrently writing shared ledgers (`ProtectedPaths` enforced by `b3-guard check-wave` and `mechanical-check`).
  - **Unblocked Unit Continuation:** if one domain unit awaits an Owner decision (`OD-*`, `WITHHELD`, `AI_NO_DECISION`), mark only that unit `blocked` and proceed on independent eligible units.

- `<product>/.b3/research-policy.json` (deterministic gate enforced by provider-neutral `b3-guard merge-policy-check`):

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

## 2. Critical Invariants Validated for `/b3-research-ship`

- `RESEARCHED != VERIFIED != IMPLEMENTED != RELEASED` and `PR_MERGED != RUNTIME_SERVED != DEPLOYED`.
- Research-only PRs (documentation, candidate notes, non-protected research units) may reach `PR_READY` even while publication/authority release remains blocked.
- `WITHHELD`, `AI_NO_DECISION`, missing `OD-*` Owner decisions, invalid digest-bound reviews, or unauthorized reviewer registrations map to `GovernanceStatus != CLEAR` (`WITHHELD_PROMOTION`, `MISSING_OWNER_DECISION`, `INVALID_EDITORIAL_REVIEW`, `UNAUTHORIZED_REVIEWER`, `UNAUTHORIZED_AUTHORITY`) → `b3-guard merge-policy-check` fails closed with `MERGE_BLOCKED` (`exit 1`).
- Never fabricate Owner decisions (`OD-*`), authority pins, witness passes, or cross-provider model provenance claims.
- Post-merge verification (`merge-policy-check -PostMerge`) confirms target-branch Git ancestry (plus optional GitHub PR merge reconciliation when `-PrNumber` is supplied), while leaving `runtime_served` and `deployed` as `NOT_VERIFIED` until live serving and deployment checks succeed independently.
