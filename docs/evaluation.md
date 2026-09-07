# Evaluation

This repository will evaluate **itself**: whether skills trigger correctly, whether their guidance is sound, and whether the review loop behaves honestly.

Application test suites for product work live in those products. Evals here live under `evals/` when they exist.

**Status:** philosophy and intended case types are specified. Eval fixtures, runners, and scored cases are **not implemented yet**.

## Skill triggering

For each skill, maintain cases in three buckets:

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

A skill fails triggering evals if it is silent on should-trigger cases, greedy on should-not-trigger cases, or consistently wins near-misses that belong elsewhere.

Trigger evals read the skill `description` and `SKILL.md` “when not to use” text. If those texts cannot separate the buckets, the skill is not ready.

## Skill quality

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

## Review-loop quality

When the loop is implemented, evals must check that it:

- catches **real bugs** in fixtures
- avoids **speculative noise**
- **fixes** findings correctly (or records why not)
- **verifies** fixes with evidence
- does **not falsely converge** (repeat findings, no-op diffs, ignored tool failures)
- **handles tool failures** as UNKNOWN / INCOMPLETE
- **respects iteration limits** and does not treat limit exhaustion as PASS

A loop that always reports success is a failed loop. A loop that always reports dozens of speculative issues is also a failed loop.

## Honesty metrics

These apply across evals:

- False PASS rate (claimed success without evidence)
- False FAIL rate (noise presented as confirmed issues)
- Stagnation escapes (loop stops with PASS while findings are unchanged)
- Skip-without-reason rate (review dimensions silently omitted)

## Adding evals later

Suggested layout (empty until real cases exist):

```text
evals/
├── skills/
├── rules/
└── review-loop/
```

Each case should record: intent, input, expected bucket or outcome, and the artifact under test. Do not generate hundreds of synthetic cases before the first skills are stable.

## What evaluation is not

- Not a substitute for verifying a product change
- Not a leaderboard for prompt cleverness
- Not an excuse to freeze the system; evals should make change safer
