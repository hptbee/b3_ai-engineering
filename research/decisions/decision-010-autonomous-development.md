# Decision 010 — Autonomous development v1

## Context

B3 already has planning, problem-solving, testing, verification, a single-pass review, and an independent review loop, each with its own command. A full feature still needs the user to invoke those commands one stage at a time. The requested addition is one invocation that runs that lifecycle until completion or a blocker.

## Options Considered

1. **Workflow + thin command.** One procedure in `workflows/`. Cursor `/autodev` selects it. Codex and Claude select the same file by prompt routing.
2. **New skill that restates the lifecycle.** Discoverable on every host, second copy of the procedure.
3. **External runner.** TypeScript or Python orchestrator, queue, or agent SDK that drives tasks outside the session.
4. **Fold into `/implement`.** Make the implement command always plan, review-loop, and commit.

## Evidence

- Layering in `docs/architecture.md`: workflows sequence; skills are methods; commands start work; adapters do not fork meaning.
- `review-loop/strategy.md` is already a one-shot orchestrator procedure without its own skill or runner.
- Codex host note (`research/validation/codex-host-v1.md`): `.cursor/commands/` are prompt-routing selectors, not native Codex slash commands.
- Claude source (`research/sources/claude-code-skills-plugins.md`): slash commands map to skills, and legacy `commands/` still works. A canonical skill would also appear in Cursor beside `/autodev`.

## Decision

**ADOPT option 1. REJECT options 2, 3, and 4.**

- Procedure: `workflows/autonomous-development.md`
- Cursor entry: `.cursor/commands/autodev.md`
- Checkpoints: `.b3/autodev/` in the repository under change (gitignored in this system repo)
- Review and fix: existing review-loop spec, strategy, and roles
- Findings: existing review-loop schema, stored in `.b3/autodev/findings.md`

No autonomous-development skill. A skill whose body repeated the workflow would be a second procedure, and a pointer skill would give Cursor two entry points for one action. Codex and Claude reach the command file the same way they reach `plan` and `review-loop`.

`/implement` stays one execution request and still does not start the review loop unless asked.

## Consequences

- Resume is checkpoint plus Git, not an automatic restart of a dead host session.
- Independent review is only as isolated as the host. Hat-change must be recorded as a limitation.
- Eval fixtures live under `evals/workflows/autonomous-development/`. The runner stays deferred (decision-005).

## Confidence

High on layering (matches existing command and review-loop split). Runtime slash-command UX and other-host discovery are not verified by this decision.
