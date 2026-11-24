# Research Ship Verification, PR & Merge Gates

On-demand gates for [`../research-ship.md`](../research-ship.md) Phases E, H, I, J, and K.

## 1. Independent Source Verification (Phase E)

Dispatch a fresh read-only verification subagent (distinct from researcher; reuse `b3-reviewer` rules + compact `<= 25L` output). Pass only `claim_id` list, `evidence-index.md`, and `sources.manifest` paths — never dump full source books.
- Verify: exact primary/secondary citation, preserved polarity/conditions, explicit `UNRESOLVED` for school conflicts, no invented operands, and `evidence-check` `exit 0`.
- Reply cap `<= 25L`: `Verdict` (`VERIFIED` | `DISPUTED` | `INCOMPLETE`), table `claim_id | status | issue | source_ref`, checked/skipped dimensions.

## 2. Dual-Gate Separation (Phase H)

| Gate | Checks | Cannot substitute for |
| --- | --- | --- |
| **Research Gate** | Source attribution, edition/school disputes, conditional predicates, uncertainty | Passing unit/integration tests |
| **Engineering Gate** | `b3-guard mechanical-check`, `symbol-check`, `verify-run`/`verify-check`, `b3-reviewer.md` (+ specialists) | Classical/domain source fidelity |
| **Editorial / Authority Gate** | Product policy (e.g., digest-bound registered AI review, Owner decision pins, `WITHHELD` stays withheld) | GitHub branch write access or PR merge |

- **Codebase routing boundary:** optional codebase MCP output (`codebase-memory` / `serena` via [`context-routing.md`](context-routing.md)) is strictly `repo-evidence` for codebase exploration and Phase G implementation; it never substitutes for verified domain sources (`evidence-check`), the **Research Gate**, or the **Editorial / Authority Gate**.

## 3. PR Lifecycle (Phase I)

1. Fetch & reconcile against `origin/main` (`git merge-base --is-ancestor origin/main HEAD`; rebase/merge if needed, then re-verify).
2. Confirm 0 blocking technical/editorial findings and passing required checks.
3. Check `gh pr list --head <branch> --state open --json number,url` first: update existing PR if open; create new PR only if none exists.
4. Inspect CI (`statusCheckRollup`) and review threads; fix confirmed blockers via [`../../review-loop/strategy.md`](../../review-loop/strategy.md) and revalidate.

## 4. Merge Eligibility & Post-Merge Verification (Phases J–K)

Run deterministic check (PS/Bash):

```text
b3-guard.{ps1,sh} merge-policy-check -PrState <OPEN|MERGED|CLOSED|NONE> -CiStatus <PASS|FAIL|PENDING|UNKNOWN> -ReviewStatus <PASS|BLOCKED|PENDING|UNKNOWN> -BlockingFindings <int> -GovernanceStatus <CLEAR|...> [-ChangedPaths <csv>] [-PolicyPath <.b3/research-policy.json>]
```

- `exit 1` (`MERGE_BLOCKED: ...`): unresolved governance (`MISSING_OWNER_DECISION`, `WITHHELD_PROMOTION`, `UNAUTHORIZED_AUTHORITY`, `INVALID_EDITORIAL_REVIEW`, `UNAUTHORIZED_REVIEWER`), protected path hit without `allow_protected_paths: true`, blocking findings, CI != `PASS`, review != `PASS`, or PR != `OPEN` → stop `BLOCKED`.
- `exit 2` (`PR_READY: auto_merge=disabled`): eligible PR with default/disabled auto-merge → stop `PR_READY` (never merge).
- `exit 0` (`MERGE_AUTHORIZED`): **only** when policy explicitly sets `"auto_merge": "authorized"` and all gates pass + branch protection/CODEOWNERS satisfied.

**Post-Merge (Phase K — only after authorized merge):**
1. Confirm GitHub reports `state == MERGED` and capture `mergeCommit.oid`.
2. Run `b3-guard.{ps1,sh} merge-policy-check -PostMerge -PrState MERGED -MergedSha <sha> -MainRef origin/main` → requires `POST_MERGE_VERIFIED` (`exit 0`).
3. Reconcile affected artifacts/coverage/authority pins and re-run `evidence-check` on changed sources.
4. Keep `runtime_served=NOT_VERIFIED` and `deployed=NOT_VERIFIED` unless separately proven by runtime/deploy checks.
