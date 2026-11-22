# Agent evals

Independent reviewer roles: `agents/b3-security-reviewer.md`, `agents/b3-architecture-reviewer.md`, `agents/b3-performance-reviewer.md`.

| Agent | Fixtures |
| --- | --- |
| `b3-performance-reviewer` | should-trigger / should-not-trigger / near-miss (hot-path vs copy vs architecture) |
| `b3-architecture-reviewer` | should-trigger / should-not-trigger / near-miss (design-only approach vs copy vs missing-diff) |

Security: still no activation cases unless misfires appear. Methods they invoke stay in skill evals.

Manual judge: `description` vs `input`. Automated runner: **not implemented**.
