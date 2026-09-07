# Review loop (runtime)

Specification: [`docs/review-loop.md`](../docs/review-loop.md).

**Status:** directories reserved; no runtime strategy, reviewers, or termination logic yet.

Intended layout:

```text
review-loop/
├── strategy/       # how to scope, iterate, and consolidate
├── reviewers/      # dimension-specific review artifacts (later)
├── verification/   # how the loop invokes verification
└── termination/    # iteration limits, stagnation, escalation
```

Do not add placeholder reviewers. When implementation starts, keep this folder operational and keep the spec in `docs/review-loop.md` so adapters do not fork the meaning.
