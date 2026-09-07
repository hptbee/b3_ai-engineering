# Research methodology

External repositories, blogs, papers, and tool docs are **research inputs**. They are not the system. Do not initialize or grow this repository by aggregating other people’s skill packs.

This document is the method. A dedicated research phase comes after initialization; this file exists so later research has a standard.

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

| Step | Do |
| --- | --- |
| Discover | Find candidate sources for a specific question, not “all AI skills on GitHub” |
| Collect | Keep links, dates, and short notes — not entire trees |
| Classify | Official spec, established practice, community, vendor blog, personal repo |
| Compare | At least two sources when the claim is not a primary specification |
| Extract patterns | Name the pattern and the problem it solves, independent of the original file layout |
| Evaluate | Fit for a *personal, portable* system; discard host lock-in and company process |
| Adapt | Rewrite into this repo’s taxonomy (rule vs skill vs knowledge) |
| Personalize | Adjust to the owner’s context without pretending it is universal |
| Verify | Check against official docs or a real task; do not trust README claims |
| Record provenance | Write the record below so a later agent can see what was borrowed |

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

Rejected patterns are valuable. Record them so the next research pass does not re-import noise.

Suggested home for provenance notes (when they exist): `knowledge/` or a research log under `references/`. Do not paste third-party `SKILL.md` files into `skills/`.

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

Research is out of scope when implementing an already-specified initialization or a well-bounded product change that only needs official docs for the stack in use.
