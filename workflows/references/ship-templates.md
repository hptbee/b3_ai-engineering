# Ship checkpoint templates

Schemas for [`../ship.md`](../ship.md). Active `{RUN_DIR}` = `.b3/ship/runs/<run_id>/` via `.b3/ship/CURRENT`. Empty template headings are not evidence.

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
- <none, or verbatim contract>
## Technical context
- canonical_checks: <CI / manifest build+typecheck+lint+test>
## Architecture
## Assumptions
## Risks
## Size and split check
- estimate: <XS|S|M|L|XL|XXL> (~<files>f, ~<lines>L, <areas> areas) | risk: <LOW|MEDIUM|HIGH|CRITICAL>
- warning: <none, or split note if >~800L or >=2 areas>

## Tasks

### T001 — <title>
- status: pending
- depends_on: []
- scope: <owned paths>
- acceptance_criteria:
  - AC1: <observable behavior>
- verification:
  - <command or probe>

## Completion criteria
## Plan changes
```

**Rules:** never recycle `id` (`T001`…); `status` ∈ `pending|in_progress|completed|blocked|incomplete`; `depends_on` = hard verified-output deps only (`integration` ∈ `pending|output_ready|integrated`); 1 commit/task; hotspots in `T001`; scope change → bump `version` + log `Plan changes` (never weaken ACs → `BLOCKED`).

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
- initial_dirty_paths: <csv or none>
- current_task: T001
- current_task_base_sha: <SHA>
- pre_fix_object: <SHA or none>
- last_wave: <none or dispatch=PARALLEL agents=<N> isolation=<mode> | dispatch=SEQUENTIAL reason=<reason>>
- run_status: running
- updated: <ISO-8601>

## Tasks
| id | status | mode | worker_root | task_base | scope | commit | verification | review | integration | impl_agent |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| T001 | in_progress | | | | | | | | | |

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

**Risk-Adaptive (`detailed`):** fill when triggered (`n/a` else): `failure_matrix`, `write_paths:` (`>=2` stores + invalidation), `io_budget:` (loops). `b3 guard fingerprint` (`task_spec_fingerprint` + `approach_at_sha`) required on multi-task, resume/handoff, or `notes`/`detailed` (optional on 1-task 1-turn `inline`).
**Context Packet:** stable prefix (role + contract + `approach/T00N.md` or `### T00N` minus `## Inspected`) + volatile suffix (`delta_files`, findings, receipt); never dump files/logs.
