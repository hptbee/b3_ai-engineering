# Independent review

Orchestrates `docs/review-loop.md`. Does **not** replace that spec.

```text
Define scope → Review (distinct from implementer) → Consolidate
→ Fix CONFIRMED → Verify → Re-review affected → Stop on clean or limit
```

| Role | Artifact |
| --- | --- |
| Reviewer (general) | `skills/engineering/code-review` |
| Security (optional) | `agents/security-reviewer.md` |
| Architecture (optional) | `agents/architecture-reviewer.md` |

Termination, finding lifecycle, false convergence: `docs/review-loop.md` only.

Evals: `evals/review-loop/`.
