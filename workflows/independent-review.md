# Independent review

Orchestrates [`docs/review-loop.md`](../docs/review-loop.md) via [`review-loop/strategy.md`](../review-loop/strategy.md). Does **not** replace the spec.

Triggered by `commands/review-loop.md` **once**. Continues until quality gate, non-convergence, or iteration limit.

```text
Size PR → full-PR loop  |  partition → unit loops → cross-cutting
```

| Role | Artifact |
| --- | --- |
| Orchestrator | `review-loop/strategy.md` |
| Reviewer | `agents/reviewer.md` → `code-review` |
| Fixer | `agents/fixer.md` |
| Security (optional) | `agents/security-reviewer.md` |
| Architecture (optional) | `agents/architecture-reviewer.md` |

Single-pass review without the loop: `commands/review.md`.
