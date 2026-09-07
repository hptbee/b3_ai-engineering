# Research methodology

External repositories, blogs, papers, and tool docs are **research inputs**. They are not the system. Do not grow this repository by aggregating other people’s skill packs.

This document is the **method**. Artifacts belong under [`../research/`](../research/README.md). A dedicated research phase comes after this foundation; do not populate `research/` with fake files in the meantime.

## Process

```text
Discover
→ Collect
→ Classify
→ Compare
→ Extract patterns
→ Evaluate
→ Adapt
→ Personalize
→ Verify
→ Record provenance
```

Map onto stores:

| Step | Do | Store |
| --- | --- | --- |
| Discover / Collect | Bounded question; links, dates, short notes — not whole trees | `research/sources/` |
| Classify | Official spec, established practice, community, vendor blog, personal repo | on the source note |
| Compare | At least two sources when the claim is not a primary specification | `research/comparisons/` |
| Extract patterns | Name the pattern and the problem, independent of original layout | `research/findings/` |
| Evaluate / Adapt / Personalize / Verify | Fit for a personal, portable system; rewrite; label taste as personal | working notes → decision |
| Record provenance | Adopt, modify, or reject with why | `research/decisions/` or `research/rejected/` |

Only after a decision should distilled content enter `knowledge/`, then `skills/`, `rules/`, or `workflows/`. See [`system-lifecycle.md`](system-lifecycle.md).

## Provenance record

For each important external pattern:

```text
Source
Pattern
Why it is useful
What problem it solves
What we changed
Why we changed it
Whether it was adopted / rejected
```

Rejected patterns are valuable. Put them in `research/rejected/` so the next pass does not re-import noise.

Do not paste third-party `SKILL.md` files into `skills/`. Do not use `references/` or `knowledge/` as a dumping ground for unprocessed sources.

## Classification of authority

Use the same honesty as the rest of the system:

| Class | Treat as |
| --- | --- |
| Official documentation / specification | Highest weight for that technology |
| Established engineering practice | Strong, still context-dependent |
| Community / research | Useful, needs corroboration |
| Personal experience | Local; label it |
| Personal preference | Not a rule |

If a GitHub skill says “always do X” with no source, it is community material at best.

## What not to do

- Do not copy large amounts of external skill content verbatim
- Do not create a meta-repo of submodules that *are* other people’s systems
- Do not import company playbooks
- Do not treat star count as correctness
- Do not skip Adapt / Personalize / Verify because the source looks polished

## When research is in scope

Research is in scope when adding a domain skill, changing a standard, or resolving a conflict between sources.

Research is out of scope when implementing an already-specified foundation change or a well-bounded product change that only needs official docs for the stack in use.
