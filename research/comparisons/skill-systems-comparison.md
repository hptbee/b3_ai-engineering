# Skill systems comparison

Compared: agentskills.io spec, Cursor, Claude Code, Codex, anthropics/skills reference, Superpowers composition.

| Dimension | agentskills.io | Cursor | Claude Code | Codex | anthropics/skills | Superpowers |
| --- | --- | --- | --- | --- | --- | --- |
| **Structure** | SKILL.md + optional dirs | Same + `assets/` | Same + plugin bundle | `.agents/skills/` | Same + marketplace | Many small skills |
| **Trigger** | description | description + paths + nested scope | description + invocation control | description (metadata visible) | description (+ pushy tuning in creator) | keyword-rich descriptions |
| **Metadata** | name, description, license, compatibility, metadata, allowed-tools† | + paths, disable-model-invocation, icon, color | + Claude extensions | Standard + repo path | Same | Standard |
| **Progressive disclosure** | 3-tier token model | Documented match | Documented match | Documented match | skill-creator TOC/refs | references per skill |
| **Portability** | Baseline standard | Loads .claude/.codex/.agents paths | CLAUDE.md separate | AGENTS.md chain, 32KiB cap | Portable SKILL bodies | Portable skills; hooks not |
| **Validation** | Trigger eval recipe | /create-skill | skill-creator eval scripts | Not documented | Eval tooling in skill-creator | writing-skills methodology |
| **Complexity** | Low spec surface | Medium (many roots) | Medium-high (plugins/hooks) | Medium | High examples | High skill count |

† `allowed-tools` experimental everywhere.

## Consensus

- Adopt agentskills.io folder + frontmatter as portable core.
- Keep host extensions out of portable SKILL.md (adapter mapping).

## Disagreements

- **Description tone:** skill-creator encourages "pushy" descriptions; near-miss evals required if following that advice.
- **Always-on methodology:** Superpowers uses SessionStart/hooks for enforcement; Cursor/Codex prefer AGENTS.md + skills without hooks in portable core.
- **Assets directory:** Cursor/Claude emphasize `assets/`; b3 skill standard omits until needed — compatible.

## Implication for b3

Stay aligned with agentskills.io; implement Cursor `paths`/`disable-model-invocation` only in adapter docs; invest in trigger evals before domain skill expansion.
