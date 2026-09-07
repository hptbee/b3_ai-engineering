# review-loop

**Action now:** run the independent review loop (review → fix → verify → re-review) per `docs/review-loop.md`.

**Not** a single `code-review` pass. Iteration limits and false-convergence rules apply.

When host subagents exist, dispatch `agents/security-reviewer.md` and `agents/architecture-reviewer.md` as **separate** passes from the implementer.

Runtime orchestration under `review-loop/` is still unspecified; follow the doc manually.
