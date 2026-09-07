# Workflows

Workflows are multi-step orchestration. They answer: **in what order should things happen?**

**Status:** present (two sequences). They sequence skills; they do not replace `docs/review-loop.md`.

| Workflow | Sequence |
| --- | --- |
| [`feature-implementation.md`](feature-implementation.md) | Understand → Plan → Implement → Verify → Review → Fix → Re-verify |
| [`independent-review.md`](independent-review.md) | One-shot adaptive loop: size → review/fix → (units + cross-cut) |

Follow `commands/review-loop.md` once; the agent continues until gate, stuck, or limit. Single-pass review remains `commands/review.md`.
