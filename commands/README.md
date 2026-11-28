# Commands

Commands are explicit, user-triggered operations. They answer: **what action should the agent perform now?**

In Cursor these files are slash-invocable. Each file selects skills; it does not duplicate skill text.

| Command | Intent |
| --- | --- |
| [`b3-plan.md`](b3-plan.md) | Risk-adaptive implementation plan with AC-to-check mapping and optional `planning` model dispatch; plan-only stop |
| [`b3-implement.md`](b3-implement.md) | Single-hop execution request (`problem-solving` + domain skill, guards, risk-sensitive review, max 2 bounded fix rounds; no `/b3-ship` escalation) |
| [`b3-debug.md`](b3-debug.md) | Broken-invariant root cause, cheapest hypothesis, sibling sweep, regression test, optional `debugging` model dispatch, and 3-attempt escalation |
| [`b3-research.md`](b3-research.md) | Lightweight read-only code explanation, investigation, tech research, or option comparison; stops when answered (no research-ship state) |
| [`b3-audit.md`](b3-audit.md) | Read-only baseline audit of a repo, subsystem, directory, or component including unchanged files when Git diff is empty |
| [`b3-review.md`](b3-review.md) | Single-pass delta-first code review (provider-neutral local guards + `symbol-check` + receipt/AC checks, optional GitHub PR read/post) |
| [`b3-refactor.md`](b3-refactor.md) | Single entrypoint for requested combination of behavior-preserving refactor, residue cleanup, and measured optimization (no auto `/b3-ship`) |
| [`b3-verify.md`](b3-verify.md) | Executed evidence for a named claim via `b3 guard verify-run`/`verify-check` (`b3-verify-v1`) receipts |
| [`b3-review-loop.md`](b3-review-loop.md) | One-shot independent loop to gate/stuck/limit (standalone `.b3/ship/review-loop/<slug>/` state + `SINGLE_AGENT_LIMIT` honesty) |
| [`b3-ship.md`](b3-ship.md) | Full lifecycle until completion, blocker, or `status` |
| [`b3-research-ship.md`](b3-research-ship.md) | Research-first autonomous delivery (`Preflight → Research → Verification → Formalization → [Impl/Review] → Branch/PR → Merge Policy`, `status`, `resume`) |
| [`b3-pr-resolve.md`](b3-pr-resolve.md) | End-to-end PR feedback lifecycle: validate, fix confirmed root causes, verify, reply, and resolve eligible review threads |
| [`b3-pr-reply.md`](b3-pr-reply.md) | Reply to selected PR review threads or comments with verified evidence (never edits code or auto-resolves threads) |
| [`b3-pr-comment.md`](b3-pr-comment.md) | Publish an existing verified B3 review result to a PR (`summary`, `inline`, `both`, or `--draft`) with SHA freshness checks |

Canonical commands live here (`commands/`). Cursor exposes them via `.cursor/commands` (`b3 sync --host cursor`); Codex, Claude Code, and Antigravity invoke the same procedures through `adapters/command-skills/` or prompt intent. Runtime host slash UX is **NOT VERIFIED** here.

## Practical distinctions and examples

- **`/b3-research` vs `/b3-research-ship`:** `/b3-research` answers bounded questions read-only and stops without `.b3/research-ship/` state (`"/b3-research explain how B3_HOME resolves"` or `"/b3-research compare sqlite vs duckdb for local cache"`). `/b3-research-ship` runs Phases A–K with manifests, implementation, PR, and governed merge.
- **`/b3-audit` vs `/b3-review`:** `/b3-audit` runs a read-only baseline inspection on existing unchanged files even with an empty Git diff (`"/b3-audit inspect auth/ for security and dead code"`). `/b3-review` inspects a local Git diff or GitHub PR (`#<id>`).
- **`/b3-refactor` vs `/b3-implement` / `/b3-ship`:** `/b3-refactor` infers scoped refactor, cleanup, or measured optimization while preserving contracts (`"/b3-refactor clean up unused helpers in src/git.rs"` or `"/b3-refactor reduce allocations in context.rs with before/after timing"`). `/b3-implement` executes new behavior changes; `/b3-ship` runs the full branch/review-loop/commit/PR lifecycle.

## Design notes

- A command selects skills and maybe a workflow.
- Do not add a command that is only an alias of a skill name unless users invoke it explicitly.
- All 14 commands (and future commands) inherit [`../workflows/references/dispatch-naming.md`](../workflows/references/dispatch-naming.md) and the proportional clarification gate (`rules/engineering-principles.md` → [`../workflows/references/clarification-gate.md`](../workflows/references/clarification-gate.md)). Parent resolves `planning:` config once per invocation, and lightweight/bounded commands apply it proportionally without loading the full rubric or pushing it into subagent worker briefs.
