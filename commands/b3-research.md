---
name: b3-research
description: "Answer a bounded engineering question, explain code, or compare options (read-only; stops when answered)."
---

# b3-research

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, host global fallback, or this repo) and answer a bounded question using relevant code, documentation, or external evidence. Infer intent from natural language (explain existing code/system behavior, investigate an engineering question, research a technology/approach, compare alternatives, or recommend an option with explicit trade-offs) — never invent a rigid flag language.

- **Scope & read-only default:** establish the question and relevant scope, reading the smallest useful set of local files or external sources. Stay read-only by default: never automatically edit product code, create a branch or PR, publish anything, or start implementation.
- **Lightweight boundary:** keep local code explanations and bounded questions lightweight — never initialize `.b3/research-ship/` state, source manifests, or an autonomous delivery lifecycle.
- **Evidence discipline:** for external research, preserve source attribution, distinguish observed evidence from inference, and keep missing or conflicting evidence visible (never invent certainty).
- **Selective reuse & routing:** apply `{B3_HOME}/skills/engineering/research-engineering-patterns/SKILL.md` only when its external-pattern adopt/reject/provenance contract fits (never indiscriminately). Route to `/b3-research-ship` (`{B3_HOME}/workflows/research-ship.md`) only when the requested scope calls for the full research-to-delivery lifecycle.
- **Dispatch & stop:** follow `{B3_HOME}/workflows/references/dispatch-naming.md` — run inline for routine bounded questions; use `SHARED_READ_ONLY` parallel exploration only when independent multi-subsystem or multi-source checks justify it. Stop when the question is answered.
- **Output:** answer or recommendation first, then supporting evidence, trade-offs, and unresolved questions proportional to the question.
