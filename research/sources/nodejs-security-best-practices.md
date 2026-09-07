# Node.js Security Best Practices

## Source

https://nodejs.org/en/learn/getting-started/security-best-practices

## Tier

Tier 1

## Purpose

Official Node.js application security guidance: threat list, mitigations, permission model notes.

## Architecture

- Extends Node threat model with **application-level** risks (not all are core Node CVEs)
- Structured as threat → explanation → mitigations with code examples
- Cross-links OSSF best practices for broader software security

## Important Patterns

| Threat | Mitigation theme |
| --- | --- |
| HTTP DoS (CWE-400) | Timeouts, reverse proxy, socket limits, Slowloris awareness |
| DNS Rebinding | `--inspect` exposure; bind inspector carefully |
| Sensitive info exposure (CWE-552) | Error handling, log redaction |
| Request smuggling (CWE-444) | Correct HTTP parsing assumptions |
| Timing attacks (CWE-208) | Constant-time comparisons for secrets |
| Malicious npm modules (CWE-1357) | Dependency hygiene, lockfiles, audit |
| Prototype pollution (CWE-1321) | Safe merge, schema validation |
| Permission model | Experimental `--permission` flag for sandboxing |

## Skill Design

Node backend skill should separate:
- **Runtime/process** security (this doc)
- **API/auth** security (OWASP API Top 10)
- **Dependency** supply chain (npm audit, pinning)

Avoid duplicating full threat list in SKILL.md — index + `references/threats.md` slices.

## Rules / Instructions

Production Node services: enforce timeouts and error handlers — candidate **repo rules**, not portable core defaults.

## Agents

N/A

## Commands / Workflows

Verification via `npm audit`, runtime probes, permission flags — ties to `verification` skill.

## Evaluation

No agent evals. Evidence = configured timeouts, audit output, test repro.

## Portability

Node-specific. Portable **method** (enumerate threats, verify mitigations) transferable; APIs differ per runtime doc.

## Strengths

- Official, maintained alongside Node releases
- Plain-language attack explanations with snippets

## Weaknesses / Trade-offs

- Not exhaustive API design guide
- Permission model still evolving
- Some mitigations assume infra (reverse proxy)

## Interesting Implementation Details

- Distinguishes core Node vs application responsibility for request body DoS

## Relevant Files

- nodejs.org/en/learn/getting-started/security-best-practices
- Node threat model document (linked from page)

## Evidence

- Fetched 2026-09-07: threat list headings, DoS/socket example, DNS rebinding on inspect

## Relevance to b3-ai-engineering

Future `backend-node-security` reference skill or section in broader backend architecture skill.

## Initial Recommendation

ADAPT — threat-index references + verification checklist; pair with OWASP for API layer
