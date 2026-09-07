# Review loop comparison

| System | Independence | Finding schema | Severity/confidence | Fix loop | Verification | Convergence | Iteration limit | Stagnation detect |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **b3 (spec)** | Required conceptually | YAML conceptual schema + lifecycle | Explicit separation | Mapped fixes | Evidence required | False convergence guards | INCOMPLETE not PASS | Listed signals |
| **SWE-Review** | Strong (reconstruction) | JSON decision/defects | confidence in decision | revise phase | Not test-gated | approve/request_changes | max 3 rounds | Not documented |
| **dev-loop** | Cross-model review | Informal + validated | implicit in validation | Claude fixes | Tests implied in reviewers | dual zero validated | default 4 | Partial (validation) |
| **Open Code Review** | Parallel + discourse | Synthesized priorities | Prioritized severities | `/ocr-address` | Human approval steps | Multi-round dirs | Implicit via rounds | Discourse helps |
| **calimero** | Multi-agent | Clustered findings | consensus score | GitHub flow | CI external | delta stabilize | Webhook-driven | **Explicit convergence** |
| **claude-review-loop** | Codex parallel | Markdown review files | OWASP/holistic lists | addressing phase | Optional | Single cycle typical | Hook phases | Weak |
| **Anthropic evaluator-optimizer** | Evaluator separate | Natural language critique | Qualitative | Regenerate | Human-like feedback loop | Until criteria met | Stopping conditions | Conceptual |

## What makes loops converge (evidence)

1. **Validated findings** before edits (dev-loop)
2. **Independent review** reducing anchoring (SWE-Review)
3. **Explicit stop states** with artifacts (JSON/markdown reports)
4. **Hard iteration caps** (SWE-Review, dev-loop)
5. **Re-verify** after fix (b3, Superpowers verification-before-completion)
6. **Delta tracking** on subsequent reviews (calimero)

## What causes waste / false success

- Shared implementer/reviewer context (anti-pattern)
- No cap (anti-pattern)
- Acting on unvalidated speculative findings (anti-pattern)
- Stop hook without re-review of fixes (claude-review-loop risk)
- Consensus suppressing valid minority findings (calimero trade-off)

## Implication for b3

Spec is strong relative to field. Runtime should prioritize: independence, finding validation, caps, stagnation detection, calmer consensus optional later.
