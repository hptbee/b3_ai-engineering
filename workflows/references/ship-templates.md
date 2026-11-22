# Ship checkpoint templates

Schemas for [`../ship.md`](../ship.md). Active `{RUN_DIR}` = `.b3/ship/runs/<run_id>/` via 1-line `.b3/ship/CURRENT`. Empty template headings are not evidence.

## 1. Master plan (`{RUN_DIR}/master-plan.md`)

```markdown
# <objective>
- version: 1
- source: <user text or path>

## Original requirements
## Scope
## Exclusions
## Invariants
- INV1: <cross-task invariant>
## Shared contracts
- <none, or exact verbatim API/type/event block copied to dependent tasks>
## Technical context
- canonical_checks: <CI / hook / manifest build+typecheck+lint+test commands>
## Architecture
## Assumptions
## Risks
## Size and split check
- estimate: <SMALL|MEDIUM|LARGE|VERY_LARGE> (~<files>f, ~<lines>L, <areas> areas)
- warning: <none, or 1-line split note when > ~800L or >= 2 independent areas>

## Tasks

### T001 — <title>
- status: pending
- depends_on: []
- scope: <owned paths/components>
- acceptance_criteria:
  - AC1: <observable behavior>
- verification:
  - <command or probe>

## Completion criteria
## Plan changes
```

**Rules:** `id` (`T001`…) never recycled; `status` ∈ `pending|in_progress|completed|blocked|incomplete`; 1 verifiable commit/task; assign hotspots (`package.json`, `.csproj`, `index.ts`, migrations, shared contracts) to 1 foundational task committed first; bump `version` + log under `Plan changes` when scope changes (never weaken ACs/drop requirements without user → `BLOCKED`).

## 2. Progress & inline approach (`{RUN_DIR}/progress.md`)

```markdown
# Progress
- run_id: <YYYYMMDD-HHMM-slug>
- b3_home: <abs path>
- product_root: <abs path>
- plan_id: <title + version>
- plan_version: 1
- branch: <branch>
- run_base_sha: <SHA>
- baseline_status: <PASS | FAIL(detail) | NOT_RUN(verify_green)>
- initial_dirty_paths: <csv paths or none>
- current_task: T001
- current_task_base_sha: <SHA>
- pre_fix_object: <SHA or none>
- run_status: running
- updated: <ISO-8601>

## Tasks
| id | status | task_base | commit | verification | review | depth | readiness | impl_agent |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| T001 | in_progress | | | | | | | |

## Approach
### T001
- depth: inline
- readiness: draft
- plan_version: 1
- approach_at_sha:
- task_spec_fingerprint:
- watched_paths:
- read_only_deps:
- reuse:
- obsoletes:
- inspected:
- files:
- changes:
- verification:

## Blockers
## Next action
## Limitations
```

## 3. Persistent approach (`{RUN_DIR}/approach/T00N.md`, `notes` / `detailed`)

```markdown
# T00N approach
- depth: notes
- readiness: draft
- plan_version: 1
- approach_at_sha:
- task_spec_fingerprint:
- watched_paths:
- read_only_deps:
- reuse:
- obsoletes:
- write_paths: n/a
- io_budget: n/a

## Inspected
## Current / desired
## Files and functions
## Contracts
## Data flow
## Edge cases
## Changes
## Tests
## Verification
## Architecture
```

**Conditional `detailed` fields:** `write_paths:` required when persisting/caching in `>= 2` stores (+ cache invalidation rule); `io_budget:` required on list/query endpoints, DB queries, or render loops; `edge_cases:` must state crash/retry/timeout/double-submit/auth outcomes when stateful/async/auth surfaces apply.
