# Autodev checkpoint templates

Reference templates for [`../autonomous-development.md`](../autonomous-development.md). Do not edit product source files from template placeholders alone.

## 1. Master plan (`.b3/autodev/master-plan.md`)

```markdown
# <objective>

- version: 1
- source: <user text or path>

## Original requirements
## Scope
## Exclusions
## Invariants
- INV1: <invariant no task may violate>
## Technical context
- canonical_checks: <build / typecheck / lint / test commands from CI/hooks/repo config>
## Architecture
## Assumptions
## Risks
## Size and split check
- estimate: <SMALL|MEDIUM|LARGE|VERY_LARGE> (~<files> files, ~<lines> lines, <areas> logical areas)
- warning: <none, or 1-line PR split suggestion when > ~800 lines or >= 2 independent areas>

## Tasks

### T001 — <title>

- status: pending
- depends_on: []
- scope: <paths or components>
- acceptance_criteria:
  - AC1: <observable behavior>
- verification:
  - <command or probe>

## Completion criteria
## Plan changes
```

### Task field rules

| Field | Rule |
| --- | --- |
| `id` | Stable (`T001`, `T002`, …). Never reuse an id for different work |
| `status` | `pending`, `in_progress`, `completed`, `blocked`, `incomplete` |
| `depends_on` | Task ids that must be `completed` first (`[]` if none) |
| `scope` | Owned component/files this task may change |
| `acceptance_criteria` | Numbered `AC1..ACn` observable behavior, not a restatement of the patch |
| `verification` | Command or probe proving each AC holds |

### Task boundaries & sizing rules

- **Size:** One independently verifiable change that can be one commit. Trivial edits stay one task; large features split into coherent slices (not a swarm of one-line tasks).
- **Contract-first & Shared Hotspots:** Shared hotspot files (`package.json`, `.csproj`, barrel `index.ts`, DB migrations, shared DTOs/contracts) belong to **one** foundational task committed first so dependent tasks via `depends_on` read committed files on disk instead of duplicating contract text.
- **Version bumps:** Increment `version` when tasks, criteria, or scope change and log the reason under `## Plan changes`. Dropping a requirement, widening scope, or changing business behavior is `BLOCKED` until the user decides. Do not weaken criteria to make incomplete work look finished.

## 2. Progress & inline approach (`.b3/autodev/progress.md`)

```markdown
# Progress

- b3_home: <absolute path>
- product_root: <absolute path>
- plan_id: <title + version>
- plan_version: 1
- branch: <branch>
- run_base_sha: <full SHA at run start>
- baseline_status: <PASS | FAIL(<detail>) | NOT_RUN(<reason>)>
- initial_dirty_paths: <comma-separated repo-relative paths or none>
- current_task: T001
- current_task_base_sha: <full SHA when T001 started>
- pre_fix_object: <commit SHA from git stash create before Fix, or none>
- run_status: running
- updated: <ISO-8601>

## Tasks

| id | status | task_base | commit | verification | review | depth | readiness |
| --- | --- | --- | --- | --- | --- | --- | --- |
| T001 | in_progress |  |  |  |  |  |  |

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
- current_desired:
- files:
- functions:
- contracts: none
- data_flow:
- edge_cases:
- changes:
- tests:
- verification:

## Blockers
## Next action
## Limitations
```

`run_status` is `running` while ready work remains; final values are `PASS`, `FAIL`, `INCOMPLETE`, or `BLOCKED`.

## 3. Persistent approach (`.b3/autodev/approach/T00N.md`, `notes` / `detailed`)

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

Conditional `detailed` fields:
- `write_paths:` Required (not `n/a`) when an entity is written/cached in `>= 2` stores (e.g., DB + cache/state); list each write path and its cache invalidation rule.
- `io_budget:` Required (not `n/a`) when touching list/query endpoints, DB queries, or render loops; state expected DB/network calls and query/index plan.
- `edge_cases:` Must cover concrete outcomes for crash/retry/timeout/double-submit/auth/permission states whenever stateful/async/auth surfaces are in scope.
