# Hook Integration Reference (On-Demand)

Canonical runtime contract for native `b3 hook` event-driven Guard integration (`0 B` always-on context cost; load on demand when configuring or troubleshooting hooks). Architecture, matrices, threat model, and 4-way benchmarks live in [`docs/hooks.md`](../../docs/hooks.md).

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

- **Zero second guard / zero subagents:** `b3 hook` delegates to `src/guard/*` (`precommit::run_for_hook`, canonical `merge_policy` helpers & `check_git_hook_operation`, `verify`, `fs`), never spawns subagents/LLMs/daemons, and sets `B3_HOOK_ACTIVE=1` for recursion protection (without disabling direct `b3 guard` calls).
- **Clarification Gate separation:** The AI Requirement Clarification Gate (`96%` threshold in `workflows/references/clarification-gate.md`) stays strictly AI-only and is never scored or prompted by hooks.

## 2. Opt-In Configuration (`[hooks]`), Precedence & Modes

Hooks are **opt-in** (`b3 hook install`) and use `[hooks]` in `~/.b3/config.toml` (`B3_CONFIG_PERSONAL`) and `<project>/.b3/config.toml` (`src/config.rs`):

```toml
[hooks]
enabled = true
mode = "enforce"   # enforce | audit | off
```

1. **Precedence:** CLI `--mode` / `B3_HOOK_MODE` (`enforce | audit | off`) > `<project>/.b3/config.toml` > `~/.b3/config.toml` (`B3_CONFIG_PERSONAL`) > default (`enabled = true`, `mode = "enforce"`).
2. **Early mode resolution & subdir discovery:** Mode is resolved before strict stdin/JSON parsing; when `--repo-root` is absent, pure-FS upward lookup walks from `cwd` to `<repo>/.b3/config.toml` (stopping at home, temp, symlinks, or first `.git`). If `--repo-root` is missing, `cwd` is outside a repo, and stdin is malformed, project preferences cannot be discovered reliably (limitation documented). `off` always exits `0` Allow; `audit` always exits `0` with `[audit]` diagnostic on stderr.
3. **Non-bypass:** `hooks.mode = "off"` disables event hooks only; mandatory workflow `b3 guard` gates in `/b3-ship`, `/b3-research-ship`, and `/b3-review-loop` stay unconditionally active.

## 3. Tiered Execution & Authority Invariants

| Tier | Budget & Scope | Events | Canonical Behavior |
| --- | --- | --- | --- |
| **Tier 0** | **`p95 < 10 ms`**, **`0` Git calls** | `BeforeFileWrite`, `BeforeCommand` | Pure-FS path containment across repo root & sibling linked worktrees (`.git` `gitdir:` file check, no Git subprocesses), `test_secret_path`, `test_checkpoint_path` (`.b3/ship/runs/*/evidence/`, `.b3/policy.toml`, `.b3/research-policy.json`, `.git/`), symlink/junction checks, optional `B3_WORKER_ALLOWED_PATHS` (not auto-propagated by IDE workflows), and provider-neutral Git lexical checks (`push --force`/`-f`, `reset --hard`, `commit --no-verify`/`-n`, `add -A`/`.`/`.b3*`, `B3_HOOK_ACTIVE=` / `B3_HOOK_MODE=`). |
| **Tier 1** | **Operation-boundary** | `BeforeCommit`, `BeforePush`, `BeforeMerge`, `AfterFileWrite`, `Stop` | `BeforeCommit` runs `precommit::run_for_hook` (`staged==WT`, checkpoints, secrets never bypassable by `B3_ALLOWED_PATHS`, optional `B3_VERIFY_RECEIPT`). `BeforePush`/`BeforeMerge` use 3-state authority (`EstablishedPolicy`, `LocalAbsentOnly`, `UnknownRemoteAuthority`), never infer remote policy absence from missing local tracking refs, check destination fetch/push URL parity, check `MERGE_HEAD` parents + **staged merge index** in `pre-merge-commit` (note: fast-forward merges skip `pre-merge-commit`), and emit non-blocking `HOOK_ADVISORY` when remote authority is unknown on feature pushes (`0` network calls). `AfterFileWrite` / completion emit receipt advisories (no-op when `continuation_active=true`). |
| **Tier 2** | **`WORKFLOW_ONLY`** | `/b3-*` workflows only | `verify-run`, `mechanical-check`, `diff-scope`, `symbol-check`, `review-inventory`, `review-ledger`, `check-wave`, `check-worktree`, `snapshot`, `evidence-check`. Never run inside event hooks. |

## 4. Minimal `B3_*` Env Contract (7) & Host Protocol Contracts

- **Active hook env vars (7 total):** `B3_HOOK_MODE`, `B3_HOOK_ACTIVE`, `B3_CONFIG_PERSONAL`, `B3_WORKER_ALLOWED_PATHS` (optional subprocess input; workflow `check-wave`/`check-worktree`/`mechanical-check` remain authoritative), `B3_ALLOWED_PATHS`, `B3_VERIFY_RECEIPT`, `B3_LEDGER_PATH`. Removed 25 speculative env vars + 7 unused `NormalizedEvent` fields (`host` + 6 prior fields).
- **Host adapter contracts:**
  - **Git shim `v3`:** `pre-commit` / `pre-merge-commit` redirect `b3 hook run </dev/null` and pass untouched caller fd 0 to `env B3_HOOK_ACTIVE=1 "$USER_HOOK" "$@"`; `pre-push` streams directly when only one hook runs and uses lossless `cat > "$TMP_STDIN"` (`mktemp` `O_EXCL` + `trap` cleanup) when chained with executable `.b3-user`; preserves original `.b3-user` permissions (never `chmod 0755`, never `sh "$USER_HOOK"`).
  - **Codex / Antigravity / Cursor / Claude:** `.codex/hooks.json` nests under `"hooks"`; Antigravity `.agents/hooks.json` uses `b3-native-guard` grouped pre/post + flat `Stop`, strips `CORTEX_STEP_TYPE_*`, and outputs `{"decision":"allow|deny|continue"}`.
- **Honesty boundary:** Local Git CLI is `LIVE_CLI_VERIFIED`; live IDE sessions (Cursor, Claude Code, Codex, Antigravity) remain `NOT_VERIFIED`.
