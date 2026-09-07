# Evaluation fixtures

Philosophy: [`docs/evaluation.md`](../docs/evaluation.md).

**Status:** framework only. No cases or runners yet. Do not add a large synthetic suite now.

Evals should cover **activation**, **capability**, **safety**, and **convergence**.

```text
evals/
├── skills/
│   └── <skill>/
│       ├── should-trigger/
│       ├── should-not-trigger/
│       └── near-miss/
│
├── rules/
│
├── agents/
│
└── review-loop/
    ├── false-positive/
    ├── false-convergence/
    ├── tool-failure/
    ├── iteration-limit/
    └── finding-lifecycle/
```

Empty nested directories are omitted until a real case exists. See [`skills/README.md`](skills/README.md), [`rules/README.md`](rules/README.md), [`agents/README.md`](agents/README.md), [`review-loop/README.md`](review-loop/README.md).
