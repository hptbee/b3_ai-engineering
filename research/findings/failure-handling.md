# Failure handling

## Observation

Reliable systems **fail closed** on missing evidence: tool failures → incomplete, not pass; unvalidated review findings discarded; iteration caps → incomplete.

## Evidence

- b3 alignment with SWE-Review structured decisions (approve vs request_changes only with report)
- dev-loop: validate findings against code before fixing
- Codex/Cursor: incomplete tool runs should not imply success (industry norm echoed in b3 rules)
- Superpowers `verification-before-completion` skill
- Anthropic agents: stopping conditions, sandbox testing

## Pattern

Explicit outcome enum: PASS | FAIL | UNKNOWN/INCOMPLETE. Never upgrade incomplete to PASS because of social pressure or tidy summaries.

## Why it matters

Agent systems' dominant failure is **false convergence** — claiming done without evidence.

## Trade-offs

Strict fail-closed frustrates users on environment limits — must surface blockers clearly

## Potential application

b3 verification rule + review-loop docs already correct. Reinforce in future review-loop runtime and evals.

## Confidence

High
