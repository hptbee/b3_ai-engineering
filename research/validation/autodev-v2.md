# Autonomous development validation v2 (hardening)

**Date:** 2026-10-12  
**Host:** Cursor Agent on Windows, repository `D:\Project\b3_ai-engineering`  
**HEAD at report time:** local uncommitted hardening on `main`  
**Scope:** F1–F6 command-first hardening. Not a product-feature `/autodev` slash-command run.

## Commands run

```text
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate-autodev-behavior.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/smoke-autodev-product.ps1
"C:\Program Files\Git\bin\bash.exe" ./scripts/validate-evals.sh
powershell -NoProfile -ExecutionPolicy Bypass -File adapters/sync-skills.ps1 -HostName codex -VerifyOnly
powershell -NoProfile -ExecutionPolicy Bypass -File adapters/sync-skills.ps1 -HostName codex
```

## Results

| Check | Result | Evidence |
| --- | --- | --- |
| Eval fixture schema | PASS | `validated 220 fixture(s)`, exit 0 |
| `validate-autodev-behavior.ps1` | PASS | empty-dir link, nonempty refuse, install pointer, idempotent install, refuse command overwrite, `.b3/` not staged/committed, SHA-not-ancestor, workflow recipes |
| `smoke-autodev-product.ps1` | PASS | Isolated git repo: install pointer, two task commits, interrupt with uncommitted README then resume without duplicating T001, residue-fix commit, `run_base..HEAD` lists all three feature commits, working tree clean except ignored `.b3/` |
| Live `.agents/skills` `-VerifyOnly` | FAIL (expected) | Empty non-link directory; exit 1 |
| Live `.agents/skills` replace | FAIL | `Access to the path ...\.agents\skills is denied` — Cursor holds the folder. Script did **not** skip with exit 0 |
| Cursor `/autodev` slash UX | NOT VERIFIED | No new Agent session listing slash commands |
| Codex skill discovery | NOT VERIFIED | Filesystem verify failed on this checkout |
| Claude Code | NOT TESTED | |
| Independent reviewer isolation in smoke | NOT VERIFIED | Smoke used hat-change residue removal, not a reviewer subagent on the toy repo |
| Procedure review | See below | Reviewer `ba7b3f1d-b4ab-4a6c-98bf-a0bc1f0297d5` |

Independent review of the hardening diff: R001 (silent overwrite of `autodev.md`) and R002 (writes before fail-closed checks) were CONFIRMED, then fixed. Re-review: both VERIFIED. Reviewer did not declare loop PASS.

Latest smoke (`scripts/smoke-autodev-product.ps1`, 2026-10-12):

```text
SMOKE PASS
run_base=9cb74bf923e3c9a656f78f47cbda0ec34043e385
T001=dbe56a9262674707c3650c6e2a5399db252c0901
T002=94b07273bfb2278c619a19c2c2cc436df3bb1133
final=3a407c6965036e2bee91093b77a9186f3734fcfc
log=
3a407c6 Remove unused greet alias left after the helper landed
94b0727 Document greet in README so the helper is discoverable
dbe56a9 Add greet helper so callers can format a hello message
```

## Classification

- **Verified here:** installer pointer + gitignore, sync-skills fail-closed in a sandbox, resume ancestry test, checkpoint not committed, cumulative git log in a toy product repo, YAML schema.
- **Documentation-based:** Codex/Claude product attach via junction flags.
- **Simulated:** YAML fixtures; smoke Git lifecycle (not a live `/autodev` invocation).
- **Not tested:** Cursor slash UX, Codex/Claude runtime, live `/autodev` on a real product, unlocking this checkout’s `.agents/skills`.

Those gaps stay `UNKNOWN / INCOMPLETE`. They are not PASS.
