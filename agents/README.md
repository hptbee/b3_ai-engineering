# Agents

Agents are specialized roles. They answer: **who should handle this?**

**Status:** specified, not implemented. There are no role prompts or subagent configs in this folder yet.

## Planned roles

| Agent | Mandate |
| --- | --- |
| `architect` | Boundaries, data flow, coupling, change impact |
| `backend-reviewer` | APIs, data, services, contracts |
| `frontend-reviewer` | UI structure, state, rendering, client architecture |
| `security-reviewer` | Trust boundaries, authn/z, secrets, injection |
| `performance-reviewer` | Hot paths, capacity, obvious algorithmic cost |
| `test-reviewer` | Whether tests could catch the risk |
| `ux-reviewer` | Usability, clarity, accessibility at a product level |
| `researcher` | Pattern research with provenance (pairs with the research skill) |

Roles are a backlog. Do not treat this list as a running multi-agent system.

## Design notes

- Independence matters most for review: implementer and reviewer should not be the same unchecked pass.
- An agent is a mandate plus constraints, not a copy of a skill. Skills stay shared.
- Host-specific subagent files belong in `adapters/`.
- Personal review taste lives in `knowledge/personal/`, not in a fake “universal reviewer”.
