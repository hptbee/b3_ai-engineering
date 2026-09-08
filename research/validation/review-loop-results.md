# Review-loop results v1

**Date:** 2026-09-07. **Method:** tabletop walkthroughs, not a product-repo run.

This file is a **historical** tabletop record (R1–R4 below). It is not current layout status.

**Current** spec and orchestrator: [`../../review-loop/spec.md`](../../review-loop/spec.md), [`../../review-loop/strategy.md`](../../review-loop/strategy.md), trigger `.cursor/commands/review-loop.md`. Finding log: [`../../review-loop/findings.md`](../../review-loop/findings.md) (session table or gitignored `review-loop/state/current.yaml`). Default SMALL/MEDIUM inner-loop cap: **5** (`strategy.md`). Host subagent isolation and real-PR exercise remain **NOT VERIFIED**. At v1 the walkthrough cited an older `docs/review-loop.md` path.

Outcomes below are tabletop, not measured on a product repo.

## R1 — Normal feature (invoice list pagination)

```text
task → implement (api-design) → independent review (code-review)
→ findings → fix → verification → decision
```

| Step | What happened |
| --- | --- |
| Scope | Add `page`/`pageSize` to `GET /invoices` |
| Review | Finding F1: unbounded list — severity medium, confidence high, CONFIRMED (code has no take/skip) |
| Fix | Add pagination |
| Verify | **INCOMPLETE** — no running API in this environment |
| Decision | Cannot PASS the loop. Spec correctly forbids inferring PASS |

**Lifecycle:** NEW → CONFIRMED → FIXED → stuck before VERIFIED. Spec is clear. **Gap:** implementer may forget verification skill unless command `verify` is used.

## R2 — Security-sensitive (BOLA)

Independent pass using `agents/security-reviewer.md` + `api-security` (not the implementer voice).

Finding:

```yaml
id: F-BOLA-1
severity: high
confidence: high
status: CONFIRMED
category: security
location: GET /orders/:id
description: No owner/tenant check; UUID is capability.
evidence: handler loads by id only (tabletop snippet)
verification: request as user A with user B's id → 404/403
```

Severity ≠ confidence held. Speculative “maybe rate limit” parked SPECULATIVE — not flooded.

**Agent A1:** Mandate says report-only, don’t implement. **Useful:** does not repeat “how to write minimal APIs”; it asks whether the object is authorized. **EFFECTIVE** as a role description. Host dispatch **NOT VERIFIED**.

## R3 — Architecture (event bus for two modules)

`architecture-reviewer` + `simplest-correct`.

Question asked: **What concrete requirement justifies this complexity?**  
No named requirement (scale, team boundary, consistency) → flag extra bus as unjustified.

Did **not** reject “because complex”. Would accept a bus if the prompt named independent deploy + failure isolation.

**Risk 6:** skill text already says complexity needs a named requirement. Command `plan` loading simplest-correct “if the plan chooses system shape” is correct. **Tune description** so “always write the shortest code” does not activate this skill (local simplicity ≠ architecture).

## R4 — Bug fix (stale form / copied props)

```text
debug → react-hooks (derive, don’t store) → fix → verification
```

Independent review after fix: check effect removed, no new effect. Verification: **INCOMPLETE** (no browser).

**False-positive handling:** “also memo the whole page” would be SPECULATIVE / out of scope — code-review says don’t flood.

## Termination

All four walks hit **INCOMPLETE** because checks could not run here. That is honest. A fake PASS would have been a failed loop.

**Ambiguous in the v1 walkthrough (since specified in `review-loop/`):**

- Default `max_iterations` — now 5 for SMALL/MEDIUM (`strategy.md`); still tunable after real PRs
- Finding file convention — `findings.md` (session or `state/current.yaml`)
- When to summon security-reviewer vs only the code-review security dimension — still a judgment call (`strategy.md` specialists)

## Commands vs loop

`review` ≠ `review-loop` is documented and held. **ADOPT** the split.
