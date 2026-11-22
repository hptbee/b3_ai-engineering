# GitHub PR review & comment reference

Reference for [`../SKILL.md`](../SKILL.md). Load **only** when reviewing a GitHub PR (`#<id>`, `<PR-URL>`, `--pr`) or posting comments/reviews to GitHub.

## 1. Context-first PR & ticket scoping (0 lockfile noise)

1. Gather PR context + file list first (never run unfiltered `gh pr diff` or raw `gh pr view --json` without `--jq` on large PRs):
   ```sh
   gh pr view <id|url> --json number,title,body,state,baseRefName,headRefName,headRefOid,files,additions,deletions,commits,comments,reviews,statusCheckRollup \
     --jq '{number, title, state, base: .baseRefName, head: .headRefName, headSha: .headRefOid, additions, deletions, body, files: [.files[].path], commits: [.commits[].messageHeadline], failedChecks: [.statusCheckRollup[]? | select(.conclusion == "FAILURE" or .state == "FAILURE" or .state == "ERROR") | (.name // .context)], comments: [.comments[] | {user: .author.login, body}], reviews: [.reviews[] | {user: .author.login, state, body}]}'
   ```
   - Read `title`, `body`, `commits`, `comments`, `reviews`, and `failedChecks` so you understand intent, CI status, and prior explanations (never repeat issues already answered in PR discussion).
   - If inline review threads exist, inspect `gh api repos/{owner}/{repo}/pulls/<id>/comments --jq '.[] | {path,line,user:.user.login,body}'` compactly.
2. **Linked ticket / issue context (GitHub Issue or Jira):**
   - Extract ticket references from PR `title`, `body`, or `headRefName` (e.g., `Closes #45`, `PROJ-123`, `https://<org>.atlassian.net/browse/PROJ-123`).
   - **GitHub Issue:** run `gh issue view <num> --json title,body,comments`.
   - **Jira ticket:** if a Jira/Atlassian CLI or MCP tool is available in the host, fetch only the ticket `summary`, `description`/ACs, and recent relevant comments (summarize to ≤ 10 lines; never dump raw JSON into context).
   - **Unavailable / missing business context:** never invent requirements. Report `CONFIRMED` technical findings from code/callers/tests and put ambiguous product intent under **Questions for author** (noting the unread ticket ID).
3. Filter out noise files before fetching/reading diffs:
   `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `bun.lockb`, `packages.lock.json`, `Cargo.lock`, `poetry.lock`, `*.min.*`, `*.snap`, `*.Designer.cs`, `*.g.cs`, `*.map`.
4. Choose diff source:
   - **Inside local clone (preferred):** fetch both base branch and PR head, compute merge-base, run deterministic guards with `--target-ref FETCH_HEAD` (`-TargetRef FETCH_HEAD` in PowerShell), then diff only `review_files`:
     ```sh
     git fetch origin <baseRefName> pull/<id>/head
     mb=$(git merge-base origin/<baseRefName> FETCH_HEAD)
     ./scripts/autodev-guard.sh diff-scope --base-sha "$mb" --target-ref FETCH_HEAD
     ./scripts/autodev-guard.sh mechanical-check --base-sha "$mb" --target-ref FETCH_HEAD
     git diff "$mb"...FETCH_HEAD -- <review_files>
     ```
   - **Outside local clone:** fetch diffs for non-noise `review_files` only via `gh api`:
     ```sh
     gh api repos/{owner}/{repo}/pulls/<id>/files --jq '.[] | select(.filename | test("(^|/)(package-lock\\.json|pnpm-lock\\.yaml|yarn\\.lock|bun\\.lockb|packages\\.lock\\.json|Cargo\\.lock|poetry\\.lock)$|\\.(min\\.(js|css)|snap|Designer\\.cs|g\\.cs|map)$") | not) | {filename, status, patch}'
     ```

## 2. Posting review / comments to GitHub PR

1. **External write gate:** Post to GitHub **only** when the user explicitly asked to post/comment on the PR (or confirms after reviewing the chat report).
2. **Verdict & signal gate:** Default to `COMMENT` (`--comment` / `"event": "COMMENT"`); never submit `APPROVE` or `REQUEST_CHANGES` unless explicitly instructed. Post **only `CONFIRMED` findings** with concrete `file:line` evidence (plus optional short **Questions for author**) — never post `SPECULATIVE` guesses to a PR.
3. **Shell-safe summary comment:** Write Markdown to a temp file and pass `--body-file`; delete the temp file afterwards. Never pass multiline Markdown with backticks or `$` via inline `-b "..."`.
   ```sh
   gh pr review <id> --comment --body-file <temp_file>
   # or: gh pr comment <id> --body-file <temp_file>
   ```
4. **Inline line-level comments (`Files changed` tab):** Write a temp JSON file and POST via `gh api --input`, then remove the temp file:
   ```json
   {
     "commit_id": "<headRefOid>",
     "event": "COMMENT",
     "body": "<summary>",
     "comments": [
       {"path": "<file>", "line": 42, "side": "RIGHT", "body": "**[HIGH]** <issue + fix>"}
     ]
   }
   ```
   ```sh
   gh api repos/{owner}/{repo}/pulls/<id>/reviews --method POST --input <temp_json>
   ```
