# Cursor: two-model review loop

Host-only note. Portable slots: [`../../review-loop/models.md`](../../review-loop/models.md). Do not copy vendor model names into `review-loop/spec.md` or skills.

## Default (committed)

`agents/b3-reviewer.md` and `agents/b3-fixer.md` (exposed to Cursor via `.cursor/agents`) use:

```yaml
model: inherit
```

Reviewer also has `readonly: true`. Orchestrator is the parent `/b3-review-loop` session.

`inherit` = same model as the parent. If Cursor does not isolate subagents, the orchestrator **hat-changes**: review pass with no edits, fix pass with no loop outcome.

## Optional tiered model routing

Edit **your checkout** (or a user-level agent file if you keep project files on `inherit`; never commit vendor model IDs):

| Role / Execution | `model:` intent |
| --- | --- |
| `agents/b3-reviewer.md`, specialists, `Orchestrator` (`Plan`/`Scope`) | **Deep / high-reasoning** |
| Complex multi-file `Build` workers (`impl_agent`) | **Standard** (escalate if retries recur) |
| Bounded surgical `Build` workers & `agents/b3-fixer.md` | **Fast / surgical edits** (escalate on Tier-1 breaker) |

Use whatever ids **this Cursor build** accepts in subagent frontmatter (the product picker / docs — not a list maintained in this repo). Official field: `model` on `.cursor/agents/*.md` ([Cursor subagents](https://cursor.com/docs/context/subagents)). Keep committed frontmatter on `model: inherit`.

## What not to do

- Do not commit a personal model id into a shared clone if others should keep `inherit`.
- Do not put model ids in `review-loop/strategy.md` or skills.
- Do not let the Reviewer edit or the Fixer declare PASS, regardless of model.

## Check

After changing `model:`, start a new Agent chat and run `/b3-review-loop`. Confirm the parent dispatches the two agents rather than reviewing and patching in one turn. Subagent auto-delegation remains **NOT VERIFIED** as a product-wide claim (`research/validation/cursor-host-v3.md`).
