# Commands

Commands are explicit, user-triggered operations. They answer: **what action should the agent perform now?**

In Cursor these files are slash-invocable. Each file selects skills; it does not duplicate skill text.

| Command | Intent |
| --- | --- |
| [`b3-plan.md`](b3-plan.md) | Risk-adaptive implementation plan with AC-to-check mapping and optional `planning` model dispatch; plan-only stop |
| [`b3-implement.md`](b3-implement.md) | Single-hop execution request (`problem-solving` + domain skill, guards, risk-sensitive review, max 2 bounded fix rounds; no `/b3-ship` escalation) |
| [`b3-debug.md`](b3-debug.md) | Broken-invariant root cause, cheapest hypothesis, sibling sweep, regression test, optional `debugging` model dispatch, and 3-attempt escalation |
| [`b3-review.md`](b3-review.md) | Single-pass delta-first code review (provider-neutral local guards + `symbol-check` + receipt/AC checks, optional GitHub PR read/post) |
| [`b3-verify.md`](b3-verify.md) | Executed evidence for a named claim via `b3 guard verify-run`/`verify-check` (`b3-verify-v1`) receipts |
| [`b3-review-loop.md`](b3-review-loop.md) | One-shot independent loop to gate/stuck/limit (standalone `.b3/ship/review-loop/<slug>/` state + `SINGLE_AGENT_LIMIT` honesty) |
| [`b3-ship.md`](b3-ship.md) | Full lifecycle until completion, blocker, or `status` |
| [`b3-research-ship.md`](b3-research-ship.md) | Research-first autonomous delivery (`Preflight → Research → Verification → Formalization → [Impl/Review] → Branch/PR → Merge Policy`, `status`, `resume`) |
| [`b3-pr-resolve.md`](b3-pr-resolve.md) | End-to-end PR feedback lifecycle: validate, fix confirmed root causes, verify, reply, and resolve eligible review threads |
| [`b3-pr-reply.md`](b3-pr-reply.md) | Reply to selected PR review threads or comments with verified evidence (never edits code or auto-resolves threads) |
| [`b3-pr-comment.md`](b3-pr-comment.md) | Publish an existing verified B3 review result to a PR (`summary`, `inline`, `both`, or `--draft`) with SHA freshness checks |

Canonical commands live here (`commands/`). Cursor exposes them via `.cursor/commands` (`b3 sync --host cursor`); Codex, Claude Code, and Antigravity invoke the same procedures through `adapters/command-skills/` or prompt intent. Runtime host slash UX is **NOT VERIFIED** here.

## Design notes

- A command selects skills and maybe a workflow.
- Do not add a command that is only an alias of a skill name unless users invoke it explicitly.
