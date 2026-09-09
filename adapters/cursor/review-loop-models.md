# Cursor: two-model review loop

Host-only note. Portable slots: [`../../review-loop/models.md`](../../review-loop/models.md). Do not copy vendor model names into `review-loop/spec.md` or skills.

## Default (committed)

`.cursor/agents/reviewer.md` and `fixer.md` use:

```yaml
model: inherit
```

Reviewer also has `readonly: true`. Orchestrator is the parent `/review-loop` session.

`inherit` = same model as the parent. If Cursor does not isolate subagents, the orchestrator **hat-changes**: review pass with no edits, fix pass with no loop outcome.

## Optional two-model

Edit **your checkout** (or a user-level agent file if you keep project files on `inherit`):

| File | `model:` intent |
| --- | --- |
| `.cursor/agents/reviewer.md` | Deeper / stronger judgment |
| `.cursor/agents/fixer.md` | Faster / surgical edits |

Use whatever ids **this Cursor build** accepts in subagent frontmatter (the product picker / docs — not a list maintained in this repo). Official field: `model` on `.cursor/agents/*.md` ([Cursor subagents](https://cursor.com/docs/context/subagents)).

Leave `security-reviewer.md` and `architecture-reviewer.md` on `inherit` unless you also want those isolated.

## What not to do

- Do not commit a personal model id into a shared clone if others should keep `inherit`.
- Do not put model ids in `review-loop/strategy.md` or skills.
- Do not let the Reviewer edit or the Fixer declare PASS, regardless of model.

## Check

After changing `model:`, start a new Agent chat and run `/review-loop`. Confirm the parent dispatches the two agents rather than reviewing and patching in one turn. Subagent auto-delegation remains **NOT VERIFIED** as a product-wide claim (`research/validation/cursor-host-v3.md`).
