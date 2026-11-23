# Pull request description template (on-demand)

Load **only** when creating or updating a pull request description. Never load into always-on sessions.

## Usage

- Write the rendered Markdown below to a temporary file outside the repo (or clean it up before finishing), then run `gh pr create --title "<title>" --body-file <tmp>` or `gh pr edit <id> --body-file <tmp>`. Remove `<tmp>` immediately after.
- Omit empty bullet placeholders, keep only observed file paths, commands, and metrics, and never claim `PASS` without executed evidence on the current change. Missing checks or unverified runtime environments stay explicit under `Not verified / Known limits (UNKNOWN / INCOMPLETE)`.

## Template

````markdown
## Summary

<!-- 1–3 concise sentences explaining what this PR changes and why. -->

## Changes

- **<Component / Area>:** <concrete change and modified path(s)>
- **<Component / Area>:** <concrete change and modified path(s)>

## Verification

<!-- List only executed checks on the current HEAD/tree with real counts/exit codes. -->
- `<command>`: PASS / FAIL (<scope or key output>)

### Not verified / Known limits (`UNKNOWN / INCOMPLETE`)

- <e.g., native macOS/Linux run, live IDE UI runtime, or "None" only if everything was directly executed>

## Risks & Compatibility

- **Breaking changes / migrations:** <none or explicit details + rollback/upgrade path>
- **Behavior / edge cases:** <key assumptions, compatibility guarantees, or before/after delta if measured>

## Checklist

- [ ] Scope matches requirements without unrelated edits or dead code/residue
- [ ] Security, error handling, and boundary validation checked
- [ ] Automated checks / tests ran after final edits with real observed results
- [ ] Affected documentation updated concisely (or no doc impact)
````
