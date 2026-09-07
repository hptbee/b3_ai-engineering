# Evaluation

This repository will evaluate **itself**: whether the right artifact activates, whether the result is good, whether failure is honest, and whether the review loop actually improves the work.

Application test suites for product work live in those products. Evals here live under `evals/` when they exist.

**Status:** framework specified. Fixtures, runners, and scored cases are **not implemented yet**. Do not add a large synthetic suite now.

## Intended layout

```text
evals/
├── skills/
│   └── <skill>/
│       ├── should-trigger/
│       ├── should-not-trigger/
│       └── near-miss/
│
├── rules/
│
├── agents/
│
└── review-loop/
    ├── false-positive/
    ├── false-convergence/
    ├── tool-failure/
    ├── iteration-limit/
    └── finding-lifecycle/
```

Empty case directories are omitted until a real case exists. See [`../evals/README.md`](../evals/README.md).

## What to test

Evaluation covers four questions. A green “it wrote something” is not enough.

### Capability

Does the system produce a **good result** when the right skill/rule/agent is used? Correctness, clarity, portability, token efficiency, progressive disclosure, verification, failure handling.

### Activation

Did the **correct** skill, rule, or agent activate?

For skills, cases in three buckets:

```text
should-trigger
should-not-trigger
near-miss
```

| Bucket | Meaning |
| --- | --- |
| Should trigger | A realistic request where this skill is the right method |
| Should not trigger | A request outside the skill, including unrelated work |
| Near miss | Related wording that should activate a *different* skill or no skill |

A skill fails activation evals if it is silent on should-trigger cases, greedy on should-not-trigger cases, or consistently wins near-misses that belong elsewhere.

Trigger evals read the skill `description` and `SKILL.md` “when not to use” text. If those texts cannot separate the buckets, the skill is not ready.

Rules and agents get analogous comply / violate / wrong-role cases when those layers exist.

### Safety

Does the system **fail safely**? Tool failure, missing diff, incomplete evidence → `UNKNOWN / INCOMPLETE` (or FAIL with remaining confirmed issues) — never a fake PASS. Preferences must not override security or hard rules ([`precedence.md`](precedence.md)).

### Convergence

Does the review loop **actually improve** the implementation? Fixes map to findings; verification runs; lifecycle moves `CONFIRMED` → `FIXED` → `VERIFIED`; the loop does not declare PASS on stagnation, identical reviews, or iteration exhaustion.

## Skill quality (capability detail)

When a skill is applied to a fixture (or a recorded real task), score at least:

| Dimension | Ask |
| --- | --- |
| Correctness | Does following it produce a sound engineering result? |
| Clarity | Can an agent execute it without improvising the method? |
| Portability | Does it avoid host-specific coupling? |
| Token efficiency | Is the main file small, with details deferred? |
| Progressive disclosure | Are references opened only when needed? |
| Verification | Does it demand evidence and forbid fake PASS? |
| Failure handling | Does it degrade to UNKNOWN / INCOMPLETE instead of guessing? |

Quality evals need fixtures with a known good outcome, not only prompt sniff tests.

## Review-loop eval folders

| Folder | Protects |
| --- | --- |
| `false-positive/` | Speculative noise not treated as confirmed defects |
| `false-convergence/` | No-op diffs, repeated findings, papered-over disagreement |
| `tool-failure/` | Failed/missing tools → INCOMPLETE, not PASS |
| `iteration-limit/` | Budget exhaustion → INCOMPLETE, not PASS |
| `finding-lifecycle/` | Status transitions and severity ≠ confidence |

A loop that always reports success is a failed loop. A loop that always reports dozens of speculative issues is also a failed loop.

## Honesty metrics

- False PASS rate (claimed success without evidence)
- False FAIL rate (noise presented as confirmed issues)
- Stagnation escapes (loop stops with PASS while findings are unchanged)
- Skip-without-reason rate (review dimensions silently omitted)

## Adding evals later

Each case should record: intent, input, expected bucket or outcome, and the artifact under test. Add a case when the behavior is worth protecting — after the research phase and first domain skills, not before.

## What evaluation is not

- Not a substitute for verifying a product change
- Not a leaderboard for prompt cleverness
- Not an excuse to freeze the system; evals should make change safer
