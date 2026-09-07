# Commands

Commands are explicit, user-triggered operations. They answer: **what action should the agent perform now?**

**Status:** specified, not implemented. There are no command entrypoints, slash-handlers, or prompt files in this folder yet.

## Planned commands

| Command | Intent |
| --- | --- |
| `research` | Investigate a question; write intake under `research/` when synthesizing into this system |
| `plan` | Produce an implementation plan without coding |
| `implement` | Execute a plan using the problem-solving skill |
| `review` | One code-review pass on the current change |
| `verify` | Run the verification skill on a named claim |
| `debug` | Problem-solving focused on a failure |
| `research-repo` | Apply research-engineering-patterns to a repository |
| `create-skill` | Author a skill that meets `docs/skill-standard.md` |
| `improve-skill` | Revise a skill using evals and provenance |
| `review-loop` | Run the independent review loop when it exists |

These names are a backlog, not a promise that they work today.

## Design notes

- A command selects skills and maybe a workflow; it is not a dump of that skill’s text.
- Host-specific invocation (`/review` vs a Cursor command) belongs in `adapters/`.
- Do not add a command until the same action has been needed more than once and a skill can back it.
