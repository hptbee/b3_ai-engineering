# Orchestrator procedure

**Trigger once:** `.cursor/commands/review-loop.md`. Do not yield after the first review for a human “run review again” unless a termination condition fires.

You are the **orchestrator**. You do not replace the reviewer or the fixer.

```text
Analyze size → choose SMALL loop or LARGE units
  → (per scope) Review → Validate → Fix → Verify → Fresh review
  → [LARGE] Cross-cutting review
  → Quality gate or STUCK
```

Reuse:

| Role | Artifact |
| --- | --- |
| Review (one pass) | `.cursor/agents/reviewer.md` → `.cursor/skills/engineering/code-review` |
| Security depth | `.cursor/agents/security-reviewer.md` when auth/API trust is in scope |
| Architecture depth | `.cursor/agents/architecture-reviewer.md` when shape/layering is in scope |
| Fix | `.cursor/agents/fixer.md` |
| Evidence | `.cursor/skills/engineering/verification` + `rules/verification.md` |
| Spec | `spec.md` |

If the host can isolate subagents, dispatch **reviewer** and **fixer** as separate roles (different context). If not, still **change hats**: reviewer pass must not edit code; fixer pass must not declare PASS.

Model slots: [`models.md`](models.md).

## 0. Establish the target

1. Identify the change (`git diff` against the PR base, or the user-named range). Empty/wrong branch → `UNKNOWN / INCOMPLETE`, stop.
2. Classify size ([`sizing.md`](sizing.md)).
3. Initialize the finding log ([`findings.md`](findings.md)). IDs are stable (`R001`…).

## 1. SMALL / MEDIUM — full-PR loop

Do **not** partition.

```text
loop iteration 1..MAX_ITERATIONS (default 5):
  Reviewer: fresh review of the current full diff (not “did we fix R00x?”)
  Orchestrator: merge into finding log; validate (drop speculative as non-blocking)
  If quality gate met → PASS (report leftover LOW/NIT)
  If stagnation / non-convergence → STUCK
  Fixer: only CONFIRMED (valid) findings that are in-scope
  Verify: build + relevant tests (`verification` skill)
  If tools did not run → INCOMPLETE, not PASS
```

## 2. LARGE / VERY_LARGE — unit loops then cross-cut

1. Partition into **logical review units** (feature / architectural boundary), not one-class crumbs. If the change is too coupled to split safely → do **not** fake units; report “split the PR” and run MEDIUM full-PR loop with the same iteration cap, or stop INCOMPLETE.
2. **Max units:** 4. If more coherent units exist, recommend splitting the PR; review the four highest-risk units plus cross-cut.
3. **Per unit:** same inner loop as SMALL, but:
   - Reviewer sees **unit diff + required interfaces/deps + applicable rules + open findings for that unit**
   - Do **not** re-send the entire PR on every unit iteration
   - **Max 3 iterations per unit** (not 5 × units)
4. Only advance to the next unit when the current unit hits the quality gate **or** is STUCK (then continue other units; overall cannot PASS).
5. **Cross-cutting review** (after units): interactions only — contracts, data flow, shared types, transactions, error propagation, integration tests. Max **2** iterations. Not a replay of every unit finding.

**Budget cap:** total reviewer passes for one invocation ≤ **12**. Exceeding that → STUCK / INCOMPLETE.

## 3. Fresh review

After fixes, the reviewer reviews **the current implementation** as an independent pass.

Forbidden as the whole review: “Are R001–R003 fixed?”

Allowed: previous IDs in the log so the reviewer does not reopen CLOSED items without **new evidence**.

Look for: bugs from fixes, wrong fixes, regressions, new edge cases, missing tests.

## 4. Finding validation (before fix)

Fixer/orchestrator classifies each OPEN item:

| Class | Action |
| --- | --- |
| Valid, in-scope, concrete | Fix (minimal) |
| Invalid / misunderstanding | REJECTED + reason |
| Already handled | CLOSED |
| Out of scope / intentional | ACCEPTED + reason |
| Stylistic / nit | leave LOW; do not block gate |
| Hypothetical, no impact | SPECULATIVE; do not fix |

Vague “this could be optimized” without a mechanism is not CONFIRMED.

## 5. Quality gate

A scope **PASS**es when:

```text
critical = 0 AND high = 0 AND medium = 0
AND build evidence PASS
AND relevant tests PASS
```

LOW/NIT may remain; list them. Never claim perfection.

Tool/build/test **did not run** → INCOMPLETE, not PASS.

## 6. Convergence and limits

After each iteration, record counts of blocking OPEN findings (critical+high+medium CONFIRMED).

**Healthy:** 8 → 4 → 1 → 0  
**Non-convergence (stop):** 5 → 5 → 6, or 4 → 4 → 4, or fix class A always births class B.

On non-convergence or cap:

```text
REVIEW LOOP DID NOT CONVERGE
```

Hand remaining OPEN items to the human. Outcome: `INCOMPLETE` (and FAIL if CONFIRMED blockers remain). **Not PASS.**

Defaults: [`spec.md`](spec.md) (`MAX_ITERATIONS = 5` for full-PR scope).

## 7. Stop and report

Always report: size class, units (if any), iteration log, finding table, what was verified, stop reason (`PASS` | `STUCK` | `INCOMPLETE`).
