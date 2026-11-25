# Pull request / merge description template (on-demand)

Load **only** when rendering a branch handoff or pull request description. Never load into always-on sessions.

## Usage (provider-neutral)

- Render to `{RUN_DIR}/pr-body.md` inside gitignored `.b3/ship/runs/<run_id>/` or `.b3/research-ship/runs/<run_id>/` (or an external `<tmp>` file deleted immediately after when no run dir exists; never dirty the working tree).
- Local/non-GitHub repos use `{RUN_DIR}/pr-body.md` directly. On GitHub remotes when publishing is requested, optionally pass `--body-file {RUN_DIR}/pr-body.md` to `gh pr create --title "<title>" --body-file <path>` or `gh pr edit <id> --body-file <path>`.
- Omit empty placeholders, keep only observed paths/commands/metrics, and never claim `PASS` without executed evidence on the current tree (`UNKNOWN / INCOMPLETE` otherwise).

## Template

````markdown
## Summary

<!-- 1–3 concise sentences explaining what this change does and why. -->

## Changes

- **<Component / Area>:** <concrete change and modified path(s)>

## Verification

<!-- Executed checks on the current HEAD/tree with observed counts/exit codes. -->
- `<command>`: PASS / FAIL (<scope or key output>)

### Not verified / Known limits (`UNKNOWN / INCOMPLETE`)

- <e.g., native macOS/Linux run, live IDE UI runtime, or "None" only if all checks ran>

## Risks & Compatibility

- **Breaking changes / migrations:** <none or details + rollback/upgrade path>
- **Behavior / edge cases:** <key assumptions, compatibility, or measured delta>

## Checklist

- [ ] Scope matches requirements without unrelated edits or dead code/residue
- [ ] Security, error handling, and boundary validation checked
- [ ] Automated checks / tests ran after final edits with observed results
- [ ] Affected documentation updated concisely (or no doc impact)
````
