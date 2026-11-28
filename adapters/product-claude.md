# Project instructions

Follow @AGENTS.md for B3 operating context, `B3_HOME` resolution, precedence, and review standards.

- Local Claude Code activation (gitignored): `.claude/skills/<name>` (core B3 skills + command skills such as `b3-ship`) and `.claude/agents` → `{B3_HOME}/agents`.
- Do not copy B3 skills into this product repository. Checkpoints and local preferences stay local under `.b3/ship/`, `.b3/research-ship/`, `.b3/pr-feedback/`, and `.b3/config.toml` (gitignored; commit `.b3/home` and `.b3/policy.toml`).
