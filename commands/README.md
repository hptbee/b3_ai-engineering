# Commands

Commands are explicit, user-triggered operations. They answer: **what action should the agent perform now?**

In Cursor these files are slash-invocable. Each file selects skills; it does not duplicate skill text.

| Command | Intent |
| --- | --- |
| [`b3-plan.md`](b3-plan.md) | Implementation plan, no coding |
| [`b3-implement.md`](b3-implement.md) | Execute via problem-solving + domain skills |
| [`b3-debug.md`](b3-debug.md) | Root-cause investigation |
| [`b3-review.md`](b3-review.md) | One code-review pass |
| [`b3-verify.md`](b3-verify.md) | Evidence for a named claim |
| [`b3-review-loop.md`](b3-review-loop.md) | One-shot independent loop to gate/stuck/limit |
| [`b3-ship.md`](b3-ship.md) | Full lifecycle until completion, blocker, or `status` |

Canonical commands live here (`commands/`). Cursor exposes them via `.cursor/commands` (`sync-skills cursor`); Codex, Claude Code, and Antigravity invoke the same procedures through `adapters/command-skills/` or prompt intent. Runtime host slash UX is **NOT VERIFIED** here.

## Design notes

- A command selects skills and maybe a workflow.
- Do not add a command that is only an alias of a skill name unless users invoke it explicitly.
