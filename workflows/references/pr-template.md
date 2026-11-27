# Pull request / merge description template (on-demand)

Load **only** when rendering a branch handoff or pull request description. Never load into always-on sessions.

## Usage (provider-neutral)

- Render to `{RUN_DIR}/pr-body.md` inside gitignored `.b3/ship/runs/<run_id>/` or `.b3/research-ship/runs/<run_id>/` (or an external `<tmp>` file deleted immediately after when no run dir exists; never dirty the working tree).
- Local/non-GitHub repos use `{RUN_DIR}/pr-body.md` directly. On GitHub remotes when publishing is requested, optionally pass `--body-file {RUN_DIR}/pr-body.md` to `gh pr create --title "<title>" --body-file <path>` or `gh pr edit <id> --body-file <path>`.
- Omit empty placeholders, keep only observed paths/commands/metrics, and keep PR titles and descriptions tool-neutral (never include `b3`/`B3` keywords or a `Verification` section in external PR descriptions).

## Template

````markdown
## Summary

<!-- 1–3 concise sentences explaining what this change does and why. -->

## Changes

- **<Component / Area>:** <concrete change and modified path(s)>

## Risks & Compatibility

- **Breaking changes / migrations:** <none or details + rollback/upgrade path>
- **Behavior / edge cases:** <key assumptions, compatibility, or measured delta>

## Checklist

- [ ] Scope matches requirements without unrelated edits or dead code/residue
- [ ] Security, error handling, and boundary validation checked
- [ ] Automated checks / tests pass cleanly
- [ ] Affected documentation updated concisely (or no doc impact)
````
