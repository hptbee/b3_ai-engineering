# Agent evals

Independent reviewer roles: `agents/security-reviewer.md`, `agents/architecture-reviewer.md`, `agents/performance-reviewer.md`.

| Agent | Fixtures |
| --- | --- |
| `performance-reviewer` | should-trigger / should-not-trigger / near-miss (hot-path vs copy vs architecture) |
| `architecture-reviewer` | should-trigger / should-not-trigger / near-miss (design-only approach vs copy vs missing-diff) |

Security: still no activation cases unless misfires appear. Methods they invoke stay in skill evals.

Manual judge: `description` vs `input`. Automated runner: **not implemented**.
