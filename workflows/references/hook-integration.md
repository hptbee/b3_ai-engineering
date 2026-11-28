# Hook Integration Reference (On-Demand)

Canonical runtime contract for native `b3 hook` event-driven Guard integration (`0 B` always-on context cost; load on demand when configuring, troubleshooting, or integrating hooks). Human architecture, matrices, threat model, and benchmarks live in [`docs/hooks.md`](../../docs/hooks.md).

## 1. Ownership Boundary (4 Layers)

```text
AI Intelligence Layer   (AGENTS.md, rules/, skills/, commands/, workflows/, review-loop/)
        │  Owns: 96% Requirement Clarification Gate, planning, architecture, semantic review
        ▼
Hook Integration Layer  (b3 hook <subcommand>)
        │  Owns: Opt-in event translation, B3_HOOK_ACTIVE=1 recursion guard, mode routing
        │  Never: duplicates Guard logic, runs LLM inference, or spawns nested subagents
        ▼
Canonical Rust Guard    (src/guard/*)
        │  Owns: Single source of truth for deterministic security, scope, receipt & policy checks
        ▼
Host Adapters & Git     (.cursor/hooks.json, .claude/settings.json, .git/hooks/*, Codex/Antigravity)
```

- **Zero second guard engine:** Hooks delegate directly to canonical primitives in `src/guard/*` (`precommit`, `merge_policy`, `mechanical`, `scope`, `freshness`, `verify`, `cache`).
- **Zero subagent / LLM orchestration:** `b3 hook` never spawns subagents, never invokes models, and never acts as a background daemon.
- **Clarification Gate separation:** The AI Requirement Clarification Gate (`96%` confidence threshold in `workflows/references/clarification-gate.md`) belongs strictly to AI planning/intake. Rust code and hooks **never** score requirement clarity, prompt for missing requirements, or enforce the `96%` threshold.

## 2. Opt-In Configuration (`hooks:`) & Precedence

Hook execution is **opt-in**: nothing runs on host or Git events until explicitly installed (`b3 hook install`) and enabled.

### Configuration locations

Reuse `~/.b3/models.md` (or `B3_MODELS_PERSONAL`) and `<project>/.b3/models.md` with an optional `hooks:` YAML block:

```yaml
hooks:
  enabled: true
  mode: enforce   # enforce | audit | off
```

### Precedence order

1. Explicit CLI flag (`--mode`) or `B3_HOOK_MODE` (`enforce | audit | off`, re-enabling unless `off`)
2. `<project>/.b3/models.md` `hooks:` block
3. `~/.b3/models.md` (or `B3_MODELS_PERSONAL`) `hooks:` block
4. Default (`enabled: true`, `mode: enforce` once explicitly installed via `b3 hook install`)

### Modes & non-bypass rule

| `mode` | Behavior | Mandatory workflow Guards |
| --- | --- | --- |
| `enforce` | Blocks unsafe Tier 0/1 actions (`BeforeFileWrite`, `BeforeCommand`, `BeforeCommit`, `BeforePush`, `BeforeMerge`); emits advisory warnings on non-blocking checks | Active |
| `audit` | Executes Tier 0/1 checks and emits diagnostic findings without blocking the host operation | Active |
| `off` | Hook dispatcher exits `0` immediately as a no-op | **Still active (cannot be bypassed)** |

**Non-bypass of mandatory workflow Guards:** Setting `hooks.mode: off` (or skipping `b3 hook install`) only disables automatic event-triggered hooks. Mandatory workflow-boundary `b3 guard` checks inside `/b3-ship`, `/b3-research-ship`, and `/b3-review-loop` (`check-wave`, `check-worktree`, `diff-scope`, `mechanical-check`, `symbol-check`, `verify-run`/`verify-check`, `precommit --require-verify-receipt`, `merge-policy-check`) remain unconditionally enforced by those workflows.

## 3. Tiered Execution Model

| Tier | Latency & Subprocess Budget | Triggered Events | Guard Modules & Behavior |
| --- | --- | --- | --- |
| **Tier 0** | **`<10 ms`**, **`0` Git subprocesses** | `BeforeFileWrite`, `BeforeCommand` | Pure in-process checks: `test_secret_path`, `test_checkpoint_path` (blocks stray edits to `.b3/ship/runs/*/evidence/`, `.b3/research-policy.json`, `.git/`), path containment / traversal / symlink & junction checks, `B3_WORKER_ALLOWED_PATHS` / `B3_PROTECTED_PATHS`, high-risk Git/PR command lexical checks (`git push --force`, `git reset --hard`, `git commit --no-verify`, `git add -A/././.b3*`, `gh pr merge` without `B3_MERGE_AUTHORIZED=1`), and `B3_HOOK_ACTIVE=1` recursion guard. |
| **Tier 1** | **Operation-boundary** (bounded Git/receipt I/O) | `BeforeCommit`, `BeforePush`, `BeforeMerge`, `AfterFileWrite`, `WorkerCompletion`, `TaskCompletion` | `BeforeCommit` → `guard::precommit` (reusing `B3_HOOK_SKIP_PRECOMMIT=1` + `B3_PRECOMMIT_VERIFIED_TREE` on exact `git write-tree` match); `BeforePush`/`BeforeMerge` → `guard::merge_policy` when `.b3/research-policy.json` exists; `AfterFileWrite` → advisory `B3_VERIFY_RECEIPT` staleness signal via `verify::test_verify_receipt`; `WorkerCompletion`/`TaskCompletion` → advisory only (no-op when `continuation_active=true`). |
| **Tier 2** | **Workflow-only (`WORKFLOW_ONLY`)** | Explicit `/b3-*` workflow steps only | Full test/build suites (`verify-run`), `review-inventory`, `review-ledger`, `symbol-check`, `check-wave --partition`, `check-worktree`, `snapshot`, `runs`, `evidence-check`, `context-cache`, full `mechanical-check` / `diff-scope`. **Never** invoked inside synchronous IDE or Git event hooks. |

## 4. Runtime Contracts: Recursion, Evidence Reuse & Degradation

- **Recursion guard (`B3_HOOK_ACTIVE=1`):** Every `b3 hook` invocation checks `B3_HOOK_ACTIVE=1` at entry and returns immediately (exit `0` allow) to prevent infinite re-entry when a hook or child `git` invocation triggers nested events. Child processes spawned by `b3 hook` inherit `B3_HOOK_ACTIVE=1`.
- **Evidence reuse (`B3_VERIFY_RECEIPT` & tree fingerprint):** When `B3_VERIFY_RECEIPT` points to a `b3-verify-v1` receipt, `BeforeCommit` forwards it to `guard::precommit` (`verify::verify_check` + `get_tree_fingerprint`, binding `HEAD` + `RelevantPaths` + working-tree blob/mode/type/gitlink hash). Valid receipts pass without re-running tests; stale/mismatched receipts fail closed in `enforce` mode.
- **Unsupported events & missing binary:**
  - Unsupported host events or missing optional fields return a clean no-op allow (`exit 0` + `UNSUPPORTED` diagnostic) rather than breaking host tool loops.
  - Installed hook wrappers must not corrupt existing user hooks; if `b3` is missing from `PATH`, wrappers surface a clear diagnostic and `b3 hook verify` detects broken wiring.
  - Malformed, oversized (`> 1 MiB`), or control-char untrusted stdin payloads fail closed (`Deny` in the host's native response format) when `--host` is recognized.
- **Verification honesty:** Static config generation, protocol parsing, and mocked CLI tests do **not** certify live IDE hook execution. Live Cursor, Claude Code, Codex, and Antigravity hook behavior remains `NOT_VERIFIED` until observed in live host sessions.
