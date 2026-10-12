# Workflows

Workflows are multi-step orchestration. They answer: **in what order should things happen?**

**Status:** present (default product sequence, plus one autonomous lifecycle). Independent review is not a third workflow file — it is `review-loop/` invoked by `.cursor/commands/review-loop.md` and by autonomous development.

| Workflow | Sequence |
| --- | --- |
| [`feature-implementation.md`](feature-implementation.md) | Understand → Plan → Implement → Verify → Review → Fix → Re-verify |
| [`autonomous-development.md`](autonomous-development.md) | Understand, plan, implement, verify, then the review loop, task commits, and resume |

Single-pass review remains `.cursor/commands/review.md`. Full loop: `.cursor/commands/review-loop.md`. Full lifecycle: `.cursor/commands/autodev.md`.
