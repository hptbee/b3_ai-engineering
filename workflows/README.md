# Workflows

Workflows are multi-step orchestration. They answer: **in what order should things happen?**

**Status:** present (one default product sequence). Independent review is not a second workflow file — it is `review-loop/` invoked by `.cursor/commands/review-loop.md`.

| Workflow | Sequence |
| --- | --- |
| [`feature-implementation.md`](feature-implementation.md) | Understand → Plan → Implement → Verify → Review → Fix → Re-verify |

Single-pass review remains `.cursor/commands/review.md`. Full loop: `.cursor/commands/review-loop.md`.
