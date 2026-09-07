# Commands

Commands are explicit, user-triggered operations. They answer: **what action should the agent perform now?**

**Status:** present (thin). Each file selects skills; it does not duplicate skill text. Host slash mapping is in `adapters/`.

| Command | Intent |
| --- | --- |
| [`plan.md`](plan.md) | Implementation plan, no coding |
| [`implement.md`](implement.md) | Execute via problem-solving + domain skills |
| [`debug.md`](debug.md) | Root-cause investigation |
| [`review.md`](review.md) | One code-review pass |
| [`verify.md`](verify.md) | Evidence for a named claim |
| [`review-loop.md`](review-loop.md) | One-shot independent loop to gate/stuck/limit |

Not implemented as host plugins. Backlog dropped: `create-skill` / `improve-skill` remain research-skill work until needed twice.

## Design notes

- A command selects skills and maybe a workflow.
- Do not add a command that is only an alias of a skill name unless users invoke it explicitly.
