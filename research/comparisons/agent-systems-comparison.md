# Agent systems comparison

Compared: Cursor subagents, Claude Code plugin agents, SWE-Review reviewer, Open Code Review team, dev-loop reviewers, calimero agents, Anthropic workflow patterns.

| Dimension | Cursor subagents | Claude plugin agents | SWE-Review reviewer | Open Code Review | dev-loop | calimero |
| --- | --- | --- | --- | --- | --- | --- |
| **Role definition** | `.cursor/agents/*.md` YAML + prompt | `agents/*.md` in plugin | Skill-driven subagent | Configurable team YAML/MD | Named review agents in code/hooks | `.ai-reviewer.yaml` agents |
| **Specialization** | Built-in Explore/Bash/Browser + custom | Custom markdown agents | Independent reconstruction | Redundant parallel reviewers | Codex + 3 Claude reviewers | security/patterns/logic/perf/style |
| **Context** | Clean window per subagent | Plugin-isolated | No patchgen context | Shared session + round dirs | JSON state file | GitHub API tool use |
| **Tool access** | model, readonly flags | hooks + MCP | Claude Code tools | Dashboard + commands | Hooks enforce phases | allow_tool_use per agent |
| **Delegation** | Parent launches | Parent/plugin | resolve workflow | Tech lead → parallel | Cross-model handoff | Aggregator |
| **Independence** | High for built-ins | Medium | **Very high** | Medium-high (discourse) | High (separate model read-only) | Medium (consensus merge) |
| **Failure handling** | Returns summary to parent | Plugin errors | JSON decision + cap | Multi-round preserve | Validated findings only | Delta convergence |

## Consensus

Independent review mandate is the strongest shared signal for code review agents.

Subagents beat skills when isolation/noise/parallelism dominate.

## Disagreements

- **Consensus vs single expert:** calimero merges; SWE-Review single reconstructor — different false-positive/false-negative tradeoffs.
- **Hook-enforced vs soft workflow:** dev-loop/claude-review-loop vs Superpowers/OCR command-driven.
- **Configuration surface:** YAML (calimero) vs markdown agents (Cursor) vs skills (SWE-Review).

## Implication for b3

Define portable agent **mandates** in `agents/` (future); generate host agent files; prioritize reviewer independence over consensus machinery in v1.
