---
name: b3-audit
description: "Read-only baseline review of a repo, subsystem, or component including unchanged files (empty diff OK)."
---

# b3-audit

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, host global fallback, or this repo) and run a read-only baseline audit via `{B3_HOME}/skills/engineering/code-review/references/baseline-audit.md` and `{B3_HOME}/skills/engineering/code-review/references/review-template.md` (load `{B3_HOME}/skills/engineering/code-review/SKILL.md` and matched domain/specialist roles on demand):
- **Scope vs `/b3-review`:** `/b3-audit` inspects existing unchanged code in a target repository, subsystem, directory, or component (empty Git diff is valid). Use `/b3-review` for Git diff / PR change reviews; never fabricate a whole-repo diff or treat `EMPTY_DIFF` / `NOISE_ONLY` / unrelated green checks as `PASS`.
- **Source state & missing targets:** record actual revision (`HEAD` SHA / branch) and relevant working-tree state, inspect target files directly, and apply deterministic checks only where semantics fit. Missing, empty, or inaccessible targets MUST report `UNKNOWN / INCOMPLETE`, never `PASS`; partial subsets never certify the whole repo.
- **Proportional parallel review:** pick only relevant dimensions (never run all specialists indiscriminately or pad categories). Partition large scopes by subsystem in `SHARED_READ_ONLY` via `{B3_HOME}/workflows/references/dispatch-naming.md` (`b3-reviewer`, `b3-{security,architecture,performance}-reviewer`), continuing unblocked subsystems and disclosing `SINGLE_AGENT_LIMIT` / `UNKNOWN` if host lacks isolation.
- **Read-only stop:** render findings (`CRITICAL|HIGH|MEDIUM|LOW`, `CONFIRMED|SPECULATIVE`), coverage gaps, and prioritized repair suggestions distinguishing defects from optional improvements. Never auto-fix, commit, or publish; route requested repairs to `/b3-implement` or `/b3-ship`.
