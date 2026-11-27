---
name: b3-research
description: "Read-only bounded question, code explanation, or trade-off research ($b3-research, /b3-research). Stops when answered; not for /b3-research-ship."
---

# b3-research

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, host global fallback, or this repo) and answer a bounded question in 1 hop from relevant code, docs, or external evidence. Infer intent from natural language (explain code/behavior, investigate a question, research an approach, compare options, or recommend with trade-offs) — no rigid flags.

- **Read-only & lightweight:** read the smallest useful set of local files or external sources; never auto-edit code, create branches/PRs, publish, start implementation, or initialize `.b3/research-ship/` state or source manifests for bounded questions.
- **Evidence & selective routing:** preserve external source attribution, separate evidence from inference, and surface missing/conflicting evidence. Open `{B3_HOME}/skills/engineering/research-engineering-patterns/SKILL.md` only when its external-pattern adopt/reject/provenance contract fits; route to `{B3_HOME}/workflows/research-ship.md` only when full research-to-delivery lifecycle scope is requested.
- **Dispatch & output:** follow `{B3_HOME}/workflows/references/dispatch-naming.md` (inline for routine questions; `SHARED_READ_ONLY` parallel exploration only when independent multi-subsystem or multi-source checks justify it). Stop when answered; report answer/recommendation first, then evidence, trade-offs, and open questions proportionally.
