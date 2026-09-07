# W3C WCAG 2 Overview

## Source

https://www.w3.org/WAI/standards-guidelines/wcag/

## Tier

Tier 1

## Purpose

Authoritative web accessibility standard: principles, success criteria, conformance levels.

## Architecture

- **WCAG 2.2** current recommendation (backwards compatible with 2.0/2.1)
- **Four principles**: Perceivable, Operable, Understandable, Robust (POUR)
- **13 guidelines**, testable **success criteria** at levels A / AA / AAA
- Supporting docs: Quick Reference, Understanding WCAG, Techniques, Test Rules

## Important Patterns

- Conformance = meet success criteria, not "best effort"
- WCAG applies to dynamic content, mobile web, multimedia; WCAG2ICT extends to native apps
- Techniques are informative; success criteria are normative
- Legal/policy references often target **AA** as practical default

## Skill Design

Accessibility skills for agents should:
- Map findings to **WCAG success criterion IDs** when claiming defects
- Distinguish **automated vs manual** checks (many AA criteria need human judgment)
- Avoid fake PASS from linter-only scans

Structure: procedure skill (review checklist) + reference links to Quick Reference — not full WCAG text in SKILL.md.

## Rules / Instructions

Product repos may adopt AA as **hard rule**; portable core stays method-focused unless user promotes to rule.

## Agents

N/A

## Commands / Workflows

Evaluation tools exist (axe, etc.) but are product verification — not part of this research source.

## Evaluation

W3C Test Rules for WCAG 2 — machine-readable rules subset; useful for capability eval design later.

## Portability

Standard is host-agnostic. Skill content portable; specific component fixes are framework-specific.

## Strengths

- Stable, citeable standard
- Clear conformance levels reduce ambiguity
- Rich supporting material without bloating core spec

## Weaknesses / Trade-offs

- Not an introduction — agents need bounded checklist, not full spec
- Many criteria not fully automatable
- WCAG 3 (Silver) still draft — stay on 2.2 for decisions

## Interesting Implementation Details

- JSON serialization of WCAG 2 on GitHub for tooling
- ISO/IEC 40500 alignment

## Relevant Files

- w3.org/TR/WCAG22/
- w3.org/WAI/WCAG22/quickref/

## Evidence

- Fetched 2026-09-07: principles, 2.2 status, conformance model, supporting docs

## Relevance to b3-ai-engineering

Future `frontend-accessibility` skill: cite WCAG IDs in review findings; integrate with `code-review` dimension until specialist skill exists.

## Initial Recommendation

ADOPT (citation standard for a11y findings); ADAPT (checklist skill + references, not spec dump)
