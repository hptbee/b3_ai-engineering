# Evaluation fixtures

Philosophy: [`docs/evaluation.md`](../docs/evaluation.md).

**Status:** layout only. No cases or runners yet.

```text
evals/
├── skills/        # should-trigger / should-not-trigger / near-miss + quality fixtures
├── rules/         # comply / violate cases for foundation rules
└── review-loop/   # false PASS, noise, stagnation, tool failure, iteration limits
```

Add a case when the behavior is worth protecting. Do not generate a large synthetic suite during early growth.
