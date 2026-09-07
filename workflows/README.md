# Workflows

Workflows are multi-step orchestration. They answer: **in what order should things happen?**

**Status:** specified, not implemented. There are no workflow files in this folder yet.

Until they exist, the default sequence is:

```text
Understand → Plan → Implement → Verify → Review → Fix → Re-verify
```

That sequence is also the backbone of `skills/engineering/problem-solving/`.

## Planned workflows (backlog)

- Feature implementation
- Defect investigation
- Independent review loop (`docs/review-loop.md`)
- Skill authoring (research → draft → eval sketch → provenance)
- Architecture change (impact → options → decision → incremental change)

## Design notes

- A workflow sequences skills, commands, and (later) agents. It does not replace them.
- Do not encode host UI into a workflow.
- Do not implement a workflow until the steps have been executed manually more than once.
