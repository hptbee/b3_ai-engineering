---
type: rule
strength: hard
scope: global
source: synthesized
authority: high
---

# Engineering principles

Hard rules for how work is done in this system.

1. **Understand before changing.** Do not edit affected targets until clear (proportional clarification gate, `96%` default; never stall independent work): `workflows/references/clarification-gate.md`.
2. **Prefer the smallest change that satisfies the success condition.** Scope expansion requires an explicit decision.
3. **Keep methods composable.** Use a focused skill; do not invent a one-off giant procedure when an existing skill applies.
4. **Do not confuse layers.** Constraints→`rules/`; methods→`skills/`; actions→`commands/`; roles→`agents/`; sequencing→`workflows/`; host wiring→`CLAUDE.md`, `adapters/`, generated host files; taste→`knowledge/personal/`.
5. **Not a company standard.** Personal, portable system; never import employer architecture or product policy.
6. **Maximum safe parallelism, not maximum agent count.** Evaluate concurrency by dependencies, ownership, risk, host limits, and cost — inline when simple, parallel when independent (`workflows/references/dispatch-naming.md`), sequential when justified.

Record tradeoffs instead of dropping principles. Conflicts: `docs/precedence.md`.
