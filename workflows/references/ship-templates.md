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

**Rules:** `id` (`T001`…) never recycled; `status` ∈ `pending|in_progress|completed|blocked|incomplete`; 1 verifiable commit/task; put hotspots (manifests, index, migrations, contracts) in task 1; scope change → bump `version` + log in `Plan changes` (never weaken ACs/requirements without user → `BLOCKED`).

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
## Edge cases / failure_matrix
## Changes
## Tests
## Verification
## Architecture
```

**Risk-Adaptive (`detailed`):** fill ONLY when triggers apply (`n/a` else): `failure_matrix` (crash/retry/idempotency/timeout/partial-fail/race/timezone/auth), `write_paths:` (`>=2` stores+invalidation), `io_budget:` (query/render loops).
**Context Packet:** stable prefix (role+immutable task/contract for prompt cache) + volatile suffix (`delta_files`, active findings, verify receipt); never paste full files/logs.
