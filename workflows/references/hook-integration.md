# Hook Integration Reference (On-Demand)

Canonical runtime contract for native `b3 hook` event-driven Guard integration (`0 B` always-on context cost; load on demand when configuring or troubleshooting hooks). Architecture, matrices, threat model, and benchmarks live in [`docs/hooks.md`](../../docs/hooks.md).

## 1. Ownership Boundary (4 Layers)

```text
AI Intelligence Layer   (AGENTS.md, rules/, skills/, commands/, workflows/, review-loop/)
        │  Owns: 96% Requirement Clarification Gate, planning, architecture, semantic review
        ▼
Hook Integration Layer  (b3 hook <subcommand>)
        │  Owns: Opt-in event translation, B3_HOOK_ACTIVE=1 recursion guard, early mode routing
        │  Never: duplicates Guard logic, runs LLM inference, or spawns nested subagents
        ▼
Canonical Rust Guard    (src/guard/*)
        │  Owns: Single source of truth for deterministic security, scope, receipt & policy checks
        ▼
Host Adapters & Git     (.cursor/hooks.json, .claude/settings.json, .codex/hooks.json, .agents/hooks.json, .git/hooks/*)
```

- **Zero second guard / zero subagents:** `b3 hook` delegates to `src/guard/*` (`precommit`, `merge_policy`, `verify`, `fs`), never spawns subagents/LLMs/daemons, and runs `B3_HOOK_ACTIVE=1` recursion protection (propagated to children).
- **Clarification Gate separation:** The AI Requirement Clarification Gate (`96%` threshold in `workflows/references/clarification-gate.md`) is strictly AI-only; Rust code and hooks never score clarity or prompt for requirements.

## 2. Opt-In Configuration (`hooks:`), Precedence & Modes

Hooks are **opt-in** (`b3 hook install`) and reuse `~/.b3/models.md` (`B3_MODELS_PERSONAL`) and `<project>/.b3/models.md`:

```yaml
hooks:
  enabled: true
  mode: enforce   # enforce | audit | off
```

1. **Precedence:** CLI `--mode` / `B3_HOOK_MODE` (`enforce | audit | off`) > `<project>/.b3/models.md` > `~/.b3/models.md` (`B3_MODELS_PERSONAL`) > default (`enabled: true`, `mode: enforce`).
2. **Early mode resolution:** Mode is resolved before strict stdin/JSON parsing so `off` (immediate exit `0` allow) and `audit` (diagnostic warning, exit `0`) remain non-blocking even on malformed payloads.
3. **Non-bypass:** `hooks.mode: off` disables event hooks only; mandatory workflow `b3 guard` gates in `/b3-ship`, `/b3-research-ship`, and `/b3-review-loop` stay unconditionally active.

## 3. Tiered Execution & Hardened Runtime Invariants

| Tier | Budget & Scope | Events | Canonical Behavior |
| --- | --- | --- | --- |
| **Tier 0** | **`<10 ms`**, **`0` Git calls** | `BeforeFileWrite`, `BeforeCommand` | Pure-FS path containment across repo root & sibling linked worktrees (`.git` `gitdir:` file check, no Git subprocesses), `test_secret_path`, `test_checkpoint_path` (`.b3/ship/runs/*/evidence/`, `.b3/research-policy.json`, `.git/`), symlink/junction checks, `B3_WORKER_ALLOWED_PATHS` / `B3_PROTECTED_PATHS`, and provider-neutral Git command checks (`push --force`/`-f`, `reset --hard`, `commit --no-verify`/`-n`, `add -A`/`.`/`.b3*`). |
| **Tier 1** | **Operation-boundary** | `BeforeCommit`, `BeforePush`, `BeforeMerge`, `AfterFileWrite`, `Stop` | `BeforeCommit` always runs canonical `guard::precommit` (reusing `B3_VERIFY_RECEIPT` via `verify_check`). `BeforePush`/`BeforeMerge` resolve canonical trunk `.b3/research-policy.json` (remote trunk authority + `parse_pre_push_stdin`, impervious to deleted WT policy) with fast skip on non-governed repos. `AfterFileWrite` emits `B3_VERIFY_RECEIPT` staleness advisories; completion events are advisory/no-op on `continuation_active=true`. |
| **Tier 2** | **`WORKFLOW_ONLY`** | `/b3-*` workflows only | `verify-run`, `mechanical-check`, `diff-scope`, `symbol-check`, `review-inventory`, `review-ledger`, `check-wave`, `check-worktree`, `snapshot`, `evidence-check`. Never run inside event hooks. |

## 4. Minimal `B3_*` Env Contract & Host Protocol Contracts

- **Active hook env vars (9 total):** `B3_HOOK_MODE`, `B3_HOOK_ACTIVE`, `B3_MODELS_PERSONAL`, `B3_PROTECTED_PATHS`, `B3_WORKER_ALLOWED_PATHS`, `B3_ALLOWED_PATHS`, `B3_VERIFY_RECEIPT`, `B3_IGNORE_DIRTY_PATHS`, `B3_LEDGER_PATH`. Removed 23 speculative env vars + 6 unused `NormalizedEvent` fields (29 speculative state items): 3 bypass/tree-cache/merge-auth vars, `B3_HOOK_REQUIRE_REPO`, `B3_EXPECTED_CMD`, `B3_RELEVANT_PATHS`, 17 `B3_PR_*`/`B3_CI_*`/`B3_HEAD_SHA` vars, and 6 `NormalizedEvent` fields.
- **Host adapter contracts:**
  - **Git shim `v2`:** Forwards stdin and `-- "$@"` to `b3 hook run --host git`, chains `<hook>.b3-user` via `env B3_HOOK_ACTIVE=1 "$USER_HOOK" "$@"` (never `sh "$USER_HOOK"`), and preserves original `.b3-user` permissions (never `chmod 0755`).
  - **Codex:** `.codex/hooks.json` wraps events under top-level `"hooks"` (`PreToolUse`, `PostToolUse`, `Stop`).
  - **Antigravity:** `b3-native-guard` uses grouped `PreToolUse`/`PostToolUse` + flat `Stop`, strips `CORTEX_STEP_TYPE_*` prefixes, and outputs `{"decision":"allow|deny|continue"}` (`continue` on `Stop` findings).
- **Degradation & honesty:** Unsupported events return clean allow (`exit 0`); oversized (`>1 MiB`) or control-char payloads fail closed in `enforce` mode. Local Git CLI is `LIVE_CLI_VERIFIED`; live IDE sessions (Cursor, Claude Code, Codex, Antigravity) remain `NOT_VERIFIED`.
