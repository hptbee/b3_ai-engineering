#!/usr/bin/env bash
# Minimal read-only trusted GitHub verification adapter for b3-guard merge-policy-check.
# Queries GitHub REST API directly via `gh api` (never trusts local JSON receipts).
# Usage: ./scripts/b3-github-verify.sh --mode pre-merge|post-merge --repo owner/repo --pr-number N
set -euo pipefail

MODE=""
REPO=""
PR_NUMBER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --pr-number) PR_NUMBER="${2:-}"; shift 2 ;;
    *) echo "GH_VERIFY_ERROR: unknown_option($1)"; exit 1 ;;
  esac
done

case "$MODE" in
  pre-merge|post-merge) ;;
  *) echo "GH_VERIFY_ERROR: invalid_mode"; exit 1 ;;
esac

REPO="$(printf '%s' "$REPO" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
if [[ ! "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ || "$REPO" == *".."* ]]; then
  echo "GH_VERIFY_ERROR: invalid_repo"
  exit 1
fi

PR_NUMBER="$(printf '%s' "$PR_NUMBER" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
if [[ ! "$PR_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "GH_VERIFY_ERROR: invalid_pr_number"
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "GH_VERIFY_ERROR: gh_cli_unavailable"
  exit 1
fi

if command -v node >/dev/null 2>&1; then
  exec node - "$MODE" "$REPO" "$PR_NUMBER" <<'NODE_EOF'
const { spawnSync } = require("child_process");

const [mode, repo, prStr] = process.argv.slice(2);
const prInt = parseInt(prStr, 10);

function fail(reason) {
  process.stdout.write(`GH_VERIFY_ERROR: ${reason}\n`);
  process.exit(1);
}

function safeText(val, field) {
  const s = val == null ? "" : String(val);
  if (/[\x00-\x1F\x7F]/.test(s)) fail(`control_chars_in_response(${field})`);
  return s;
}

function sortUnique(arr) {
  const set = new Set();
  for (const x of arr) {
    if (x) set.add(x);
  }
  return Array.from(set).sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
}

function ghApi(args) {
  const r = spawnSync("gh", ["api", ...args], {
    encoding: "utf8",
    maxBuffer: 32 * 1024 * 1024,
  });
  if (r.error) {
    fail("gh_cli_unavailable");
  }
  return {
    code: typeof r.status === "number" ? r.status : 1,
    stdout: r.stdout || "",
    stderr: r.stderr || "",
  };
}

function hasHttp(res, code) {
  const txt = `${res.stderr}\n${res.stdout}`;
  const re1 = new RegExp(`\\bHTTP\\s+${code}\\b`, "i");
  const re2 = new RegExp(`"status"\\s*:\\s*"${code}"`, "i");
  return re1.test(txt) || re2.test(txt);
}

function parseJson(raw, ctx) {
  if (!raw || !raw.trim()) fail(`empty_json(${ctx})`);
  try {
    return JSON.parse(raw);
  } catch (e) {
    fail(`invalid_json(${ctx})`);
  }
}

function flattenPages(parsed) {
  if (!Array.isArray(parsed)) return parsed == null ? [] : [parsed];
  const out = [];
  for (const el of parsed) {
    if (Array.isArray(el)) {
      for (const sub of el) if (sub != null) out.push(sub);
    } else if (el != null) {
      out.push(el);
    }
  }
  return out;
}

const prRes = ghApi([`repos/${repo}/pulls/${prStr}`]);
if (prRes.code !== 0) {
  if (hasHttp(prRes, 404)) fail("pr_not_found");
  if (hasHttp(prRes, 401)) fail("github_auth_failed");
  if (hasHttp(prRes, 403)) fail("github_access_denied");
  fail("pr_query_failed");
}
const prObj = parseJson(prRes.stdout, "pull");
if (!prObj || typeof prObj !== "object" || Number(prObj.number) !== prInt) {
  fail("pr_number_mismatch");
}

const baseObj = prObj.base || {};
const headObj = prObj.head || {};
const baseRepoObj = baseObj.repo || {};
const headRepoObj = headObj.repo || null;
const userObj = prObj.user || {};

const baseRepoFull = safeText(baseRepoObj.full_name, "base_repo").trim();
if (!baseRepoFull || baseRepoFull.toLowerCase() !== repo.toLowerCase()) {
  fail("cross_repo_mismatch");
}
const defaultBranch = safeText(baseRepoObj.default_branch, "default_branch").trim();
if (!defaultBranch) fail("missing_default_branch");

const baseRef = safeText(baseObj.ref, "base_ref").trim();
const prBaseSha = safeText(baseObj.sha, "pr_base_sha").trim().toLowerCase();
const headRef = safeText(headObj.ref, "head_ref").trim();
const headSha = safeText(headObj.sha, "head_sha").trim().toLowerCase();
if (!baseRef || !/^[0-9a-f]{40}$/.test(prBaseSha) || !/^[0-9a-f]{40}$/.test(headSha)) {
  fail("incomplete_pr_refs");
}

const prState = safeText(prObj.state, "pr_state").trim().toUpperCase();
if (prState !== "OPEN" && prState !== "CLOSED") fail(`invalid_pr_state(${prState})`);

const prMerged = prObj.merged === true;
const mergedAt = prObj.merged_at ? safeText(prObj.merged_at, "merged_at").trim() : "none";
const mergeCommitSha = prObj.merge_commit_sha
  ? safeText(prObj.merge_commit_sha, "merge_commit_sha").trim().toLowerCase()
  : "none";
if (mergeCommitSha !== "none" && !/^[0-9a-f]{40}$/.test(mergeCommitSha)) {
  fail("invalid_merge_commit_sha");
}

if (mode === "post-merge") {
  const prCommits = typeof prObj.commits === "number" ? prObj.commits : 0;
  let liveTargetSha = "none";
  let compareStatus = "not_merged";
  let compareBehind = -1;

  if (prMerged && /^[0-9a-f]{40}$/.test(mergeCommitSha)) {
    const encBase = encodeURIComponent(baseRef);
    const brRes = ghApi([`repos/${baseRepoFull}/branches/${encBase}`]);
    if (brRes.code !== 0) {
      if (hasHttp(brRes, 404)) {
        compareStatus = "target_branch_missing";
      } else {
        fail("target_branch_query_failed");
      }
    } else {
      const brObj = parseJson(brRes.stdout, "target_branch");
      const ltSha = safeText((brObj.commit || {}).sha, "live_target_sha").trim().toLowerCase();
      if (!/^[0-9a-f]{40}$/.test(ltSha)) fail("invalid_live_target_sha");
      liveTargetSha = ltSha;

      const cmpRes = ghApi([`repos/${baseRepoFull}/compare/${mergeCommitSha}...${liveTargetSha}`]);
      if (cmpRes.code !== 0) fail("compare_query_failed");
      const cmpObj = parseJson(cmpRes.stdout, "compare");
      const cStat = safeText(cmpObj.status, "compare_status").trim().toLowerCase();
      if (!["identical", "ahead", "behind", "diverged"].includes(cStat)) {
        fail(`invalid_compare_status(${cStat})`);
      }
      compareStatus = cStat;
      compareBehind = typeof cmpObj.behind_by === "number" ? cmpObj.behind_by : -1;
    }
  }

  const lines = [
    "schema=b3-gh-verify-v1",
    "mode=post-merge",
    `repo=${repo}`,
    `pr_number=${prInt}`,
    `base_repo=${baseRepoFull}`,
    `default_branch=${defaultBranch}`,
    `pr_state=${prState}`,
    `pr_merged=${prMerged ? "true" : "false"}`,
    `merged_at=${mergedAt}`,
    `merge_commit_sha=${mergeCommitSha}`,
    `base_ref=${baseRef}`,
    `head_sha=${headSha}`,
    `pr_commits=${prCommits}`,
    `live_target_sha=${liveTargetSha}`,
    `compare_status=${compareStatus}`,
    `compare_behind_by=${compareBehind}`,
  ];
  process.stdout.write(lines.join("\n") + "\n");
  process.exit(0);
}

// --- pre-merge mode ---
const headRepoFull =
  headRepoObj && headRepoObj.full_name
    ? safeText(headRepoObj.full_name, "head_repo").trim()
    : "none";
const sameRepo = headRepoFull !== "none" && headRepoFull.toLowerCase() === baseRepoFull.toLowerCase();
const prDraft = prObj.draft === true;
const prAuthor = safeText(userObj.login, "pr_author").trim();
if (!prAuthor) fail("missing_pr_author");

const mergeableStr =
  typeof prObj.mergeable === "boolean" ? (prObj.mergeable ? "true" : "false") : "unknown";
const mergeableState = prObj.mergeable_state
  ? safeText(prObj.mergeable_state, "mergeable_state").trim().toLowerCase()
  : "unknown";

const encBaseRef = encodeURIComponent(baseRef);
const baseBrRes = ghApi([`repos/${baseRepoFull}/branches/${encBaseRef}`]);
if (baseBrRes.code !== 0) fail("target_branch_query_failed");
const baseBrObj = parseJson(baseBrRes.stdout, "target_branch");
const liveTargetSha = safeText((baseBrObj.commit || {}).sha, "live_target_sha")
  .trim()
  .toLowerCase();
if (!/^[0-9a-f]{40}$/.test(liveTargetSha)) fail("invalid_live_target_sha");
const branchProtected = baseBrObj.protected === true;

const reqChecksList = [];
let reqReviewsCount = 0;
let reqCodeowners = false;

if (baseBrObj.protection && baseBrObj.protection.required_status_checks) {
  const rsc = baseBrObj.protection.required_status_checks;
  for (const ctx of Array.isArray(rsc.contexts) ? rsc.contexts : []) {
    if (typeof ctx === "string" && ctx.trim()) reqChecksList.push(safeText(ctx.trim(), "required_check"));
  }
  for (const chk of Array.isArray(rsc.checks) ? rsc.checks : []) {
    if (chk && typeof chk.context === "string" && chk.context.trim()) {
      reqChecksList.push(safeText(chk.context.trim(), "required_check"));
    }
  }
}

const policyAuthorityRef = defaultBranch;
let policyAuthoritySha = liveTargetSha;
if (defaultBranch !== baseRef) {
  const encDef = encodeURIComponent(defaultBranch);
  const defBrRes = ghApi([`repos/${baseRepoFull}/branches/${encDef}`]);
  if (defBrRes.code !== 0) fail("policy_authority_query_failed");
  const defBrObj = parseJson(defBrRes.stdout, "default_branch");
  policyAuthoritySha = safeText((defBrObj.commit || {}).sha, "policy_authority_sha")
    .trim()
    .toLowerCase();
  if (!/^[0-9a-f]{40}$/.test(policyAuthoritySha)) fail("invalid_policy_authority_sha");
}

const rulesRes = ghApi(["--paginate", "--slurp", `repos/${baseRepoFull}/rules/branches/${encBaseRef}?per_page=100`]);
if (rulesRes.code === 0) {
  const rulesArr = flattenPages(parseJson(rulesRes.stdout, "branch_rules"));
  for (const r of rulesArr) {
    if (!r || typeof r !== "object") continue;
    const p = r.parameters || {};
    if (r.type === "pull_request") {
      if (typeof p.required_approving_review_count === "number" && p.required_approving_review_count > reqReviewsCount) {
        reqReviewsCount = p.required_approving_review_count;
      }
      if (p.require_code_owner_review === true) reqCodeowners = true;
    } else if (r.type === "required_status_checks") {
      for (const rc of Array.isArray(p.required_status_checks) ? p.required_status_checks : []) {
        if (rc && typeof rc.context === "string" && rc.context.trim()) {
          reqChecksList.push(safeText(rc.context.trim(), "ruleset_check"));
        }
      }
    }
  }
} else if (!hasHttp(rulesRes, 404)) {
  fail("branch_rules_unavailable");
}

let branchProtectionReadable = true;
if (branchProtected) {
  const protRes = ghApi([`repos/${baseRepoFull}/branches/${encBaseRef}/protection`]);
  if (protRes.code === 0) {
    const protObj = parseJson(protRes.stdout, "branch_protection");
    if (protObj.required_status_checks) {
      const rsc = protObj.required_status_checks;
      for (const ctx of Array.isArray(rsc.contexts) ? rsc.contexts : []) {
        if (typeof ctx === "string" && ctx.trim()) reqChecksList.push(safeText(ctx.trim(), "prot_check"));
      }
      for (const chk of Array.isArray(rsc.checks) ? rsc.checks : []) {
        if (chk && typeof chk.context === "string" && chk.context.trim()) {
          reqChecksList.push(safeText(chk.context.trim(), "prot_check"));
        }
      }
    }
    if (protObj.required_pull_request_reviews) {
      const prr = protObj.required_pull_request_reviews;
      if (typeof prr.required_approving_review_count === "number" && prr.required_approving_review_count > reqReviewsCount) {
        reqReviewsCount = prr.required_approving_review_count;
      }
      if (prr.require_code_owner_reviews === true) reqCodeowners = true;
    }
  } else if (hasHttp(protRes, 403) || hasHttp(protRes, 404)) {
    branchProtectionReadable = false;
  } else {
    fail("branch_protection_unavailable");
  }
}

const reqChecksArr = sortUnique(reqChecksList);

const filesRes = ghApi(["--paginate", "--slurp", `repos/${baseRepoFull}/pulls/${prStr}/files?per_page=100`]);
if (filesRes.code !== 0) fail("pr_files_query_failed");
const fileItems = flattenPages(parseJson(filesRes.stdout, "pr_files"));
const prChangedList = [];
for (const fi of fileItems) {
  if (!fi || typeof fi !== "object") continue;
  if (typeof fi.filename === "string" && fi.filename.trim()) {
    prChangedList.push(safeText(fi.filename.trim().replace(/\\/g, "/"), "pr_file"));
  }
  if (typeof fi.previous_filename === "string" && fi.previous_filename.trim()) {
    prChangedList.push(safeText(fi.previous_filename.trim().replace(/\\/g, "/"), "pr_prev_file"));
  }
}
const prChangedSorted = sortUnique(prChangedList);

const revRes = ghApi(["--paginate", "--slurp", `repos/${baseRepoFull}/pulls/${prStr}/reviews?per_page=100`]);
if (revRes.code !== 0) fail("pr_reviews_query_failed");
const revItems = flattenPages(parseJson(revRes.stdout, "pr_reviews"));
const latestByReviewer = new Map();
for (const rv of revItems) {
  if (!rv || typeof rv !== "object") continue;
  const st = safeText(rv.state, "review_state").trim().toUpperCase();
  if (!["APPROVED", "CHANGES_REQUESTED", "DISMISSED"].includes(st)) continue;
  const login = safeText((rv.user || {}).login, "review_user").trim();
  if (!login) continue;
  const userType = safeText((rv.user || {}).type, "review_user_type").trim();
  const assoc = safeText(rv.author_association, "review_author_association").trim().toUpperCase();
  const commit = rv.commit_id ? safeText(rv.commit_id, "review_commit").trim().toLowerCase() : "";
  latestByReviewer.set(login.toLowerCase(), { login, state: st, commit, userType, assoc });
}

const authorLower = prAuthor.toLowerCase();
const allowedAssocs = new Set(["OWNER", "MEMBER", "COLLABORATOR"]);
let changesReqCnt = 0;
let selfApprovedCnt = 0;
let unauthApprovedCnt = 0;
let staleIndepCnt = 0;
const indepReviewersList = [];
for (const [key, rec] of latestByReviewer.entries()) {
  if (rec.state === "CHANGES_REQUESTED") {
    changesReqCnt++;
  } else if (rec.state === "APPROVED") {
    if (key === authorLower) {
      if (rec.commit === headSha) selfApprovedCnt++;
    } else if (rec.userType !== "User" || !allowedAssocs.has(rec.assoc)) {
      if (rec.commit === headSha) unauthApprovedCnt++;
    } else if (rec.commit === headSha) {
      indepReviewersList.push(rec.login);
    } else {
      staleIndepCnt++;
    }
  }
}
const indepReviewersArr = sortUnique(indepReviewersList);
const indepApprovedCnt = indepReviewersArr.length;

let ghReviewStatus = "PENDING";
if (changesReqCnt > 0) {
  ghReviewStatus = "BLOCKED";
} else if (indepApprovedCnt > 0 && indepApprovedCnt >= reqReviewsCount) {
  ghReviewStatus = "PASS";
} else if (indepApprovedCnt === 0 && selfApprovedCnt > 0) {
  ghReviewStatus = "SELF_REVIEW_ONLY";
} else if (indepApprovedCnt === 0 && unauthApprovedCnt > 0) {
  ghReviewStatus = "UNAUTHORIZED_ONLY";
} else if (indepApprovedCnt === 0 && staleIndepCnt > 0) {
  ghReviewStatus = "STALE";
}

const crRes = ghApi(["--paginate", "--slurp", `repos/${baseRepoFull}/commits/${headSha}/check-runs?per_page=100`]);
if (crRes.code !== 0) fail("check_runs_query_failed");
const crRaw = parseJson(crRes.stdout, "check_runs");
const crPages = Array.isArray(crRaw) ? crRaw : [crRaw];
const latestChecks = new Map();
for (const pg of crPages) {
  if (!pg || !Array.isArray(pg.check_runs)) continue;
  for (const run of pg.check_runs) {
    if (!run || typeof run !== "object") continue;
    if (run.head_sha && String(run.head_sha).trim().toLowerCase() !== headSha) {
      fail("check_run_sha_mismatch");
    }
    const name = safeText(run.name, "check_name").trim();
    if (!name) continue;
    const appId = run.app && run.app.id != null ? String(run.app.id) : "0";
    const cKey = `${appId}\0${name}`;
    const id = typeof run.id === "number" ? run.id : 0;
    const status = safeText(run.status, "check_status").trim().toLowerCase();
    const conclusion = run.conclusion ? safeText(run.conclusion, "check_conclusion").trim().toLowerCase() : "";
    const prev = latestChecks.get(cKey);
    if (!prev || id >= prev.id) {
      latestChecks.set(cKey, { name, id, status, conclusion });
    }
  }
}

const stRes = ghApi(["--paginate", "--slurp", `repos/${baseRepoFull}/commits/${headSha}/status?per_page=100`]);
if (stRes.code !== 0) fail("commit_status_query_failed");
const stRaw = parseJson(stRes.stdout, "commit_status");
const stPages = Array.isArray(stRaw) ? stRaw : [stRaw];
const latestStatuses = new Map();
let combinedStatusFailed = false;
let combinedStatusPending = false;
for (const stObj of stPages) {
  if (!stObj || typeof stObj !== "object") continue;
  if (stObj.sha && String(stObj.sha).trim().toLowerCase() !== headSha) {
    fail("commit_status_sha_mismatch");
  }
  const stTotal = typeof stObj.total_count === "number" ? stObj.total_count : 0;
  const stTopState = safeText(stObj.state, "status_top_state").trim().toLowerCase();
  if (stTotal > 0) {
    if (stTopState === "failure" || stTopState === "error") combinedStatusFailed = true;
    else if (stTopState === "pending") combinedStatusPending = true;
  }
  for (const stItem of Array.isArray(stObj.statuses) ? stObj.statuses : []) {
    if (!stItem || typeof stItem !== "object") continue;
    const ctx = safeText(stItem.context, "status_context").trim();
    if (!ctx || latestStatuses.has(ctx)) continue;
    latestStatuses.set(ctx, safeText(stItem.state, "status_state").trim().toLowerCase());
  }
}

let hasFailed = combinedStatusFailed;
let hasPending = false;
const passedSet = new Set();
const failedNames = new Set();
let totalChecksSeen = 0;
let successCount = 0;

for (const c of latestChecks.values()) {
  totalChecksSeen++;
  if (c.status !== "completed") {
    hasPending = true;
    failedNames.add(c.name);
  } else if (c.conclusion === "success") {
    successCount++;
    passedSet.add(c.name);
  } else if (c.conclusion === "neutral" || c.conclusion === "skipped") {
    passedSet.add(c.name);
  } else {
    hasFailed = true;
    failedNames.add(c.name);
  }
}
for (const [ctx, st] of latestStatuses.entries()) {
  totalChecksSeen++;
  if (st === "success") {
    successCount++;
    passedSet.add(ctx);
  } else if (st === "pending") {
    hasPending = true;
    failedNames.add(ctx);
  } else {
    hasFailed = true;
    failedNames.add(ctx);
  }
}
if (combinedStatusPending && latestStatuses.size === 0) {
  hasPending = true;
}

const missingReqArr = sortUnique(reqChecksArr.filter((rc) => !passedSet.has(rc) || failedNames.has(rc)));

let ghCiStatus = "PASS";
if (hasFailed) {
  ghCiStatus = "FAIL";
} else if (hasPending) {
  ghCiStatus = "PENDING";
} else if (missingReqArr.length > 0) {
  ghCiStatus = "MISSING_REQUIRED";
} else if (totalChecksSeen === 0 || successCount === 0) {
  ghCiStatus = "UNKNOWN";
}

const outLines = [
  "schema=b3-gh-verify-v1",
  "mode=pre-merge",
  `repo=${repo}`,
  `pr_number=${prStr}`,
  `base_repo=${baseRepoFull}`,
  `head_repo=${headRepoFull}`,
  `same_repo=${sameRepo ? "true" : "false"}`,
  `default_branch=${defaultBranch}`,
  `pr_state=${prState}`,
  `pr_merged=${prMerged ? "true" : "false"}`,
  `pr_draft=${prDraft ? "true" : "false"}`,
  `pr_author=${prAuthor}`,
  `base_ref=${baseRef}`,
  `pr_base_sha=${prBaseSha}`,
  `live_target_sha=${liveTargetSha}`,
  `head_ref=${headRef}`,
  `head_sha=${headSha}`,
  `policy_authority_ref=${policyAuthorityRef}`,
  `policy_authority_sha=${policyAuthoritySha}`,
  `mergeable=${mergeableStr}`,
  `mergeable_state=${mergeableState}`,
  `branch_protected=${branchProtected ? "true" : "false"}`,
  `branch_protection_readable=${branchProtectionReadable ? "true" : "false"}`,
  `required_approving_reviews=${reqReviewsCount}`,
  `require_codeowners=${reqCodeowners ? "true" : "false"}`,
  `required_checks=${reqChecksArr.length > 0 ? reqChecksArr.join(",") : "none"}`,
  `missing_required_checks=${missingReqArr.length > 0 ? missingReqArr.join(",") : "none"}`,
  `gh_ci_status=${ghCiStatus}`,
  `gh_review_status=${ghReviewStatus}`,
  `independent_approved_count=${indepApprovedCnt}`,
  `stale_independent_approved_count=${staleIndepCnt}`,
  `self_approved_count=${selfApprovedCnt}`,
  `unauthorized_approved_count=${unauthApprovedCnt}`,
  `changes_requested_count=${changesReqCnt}`,
  `independent_reviewers=${indepReviewersArr.length > 0 ? indepReviewersArr.join(",") : "none"}`,
];
for (const cf of prChangedSorted) {
  outLines.push(`pr_changed_file=${cf}`);
}
process.stdout.write(outLines.join("\n") + "\n");
process.exit(0);
NODE_EOF
fi

PY_CMD=""
if command -v python3 >/dev/null 2>&1 && python3 --version >/dev/null 2>&1; then
  PY_CMD="python3"
elif command -v python >/dev/null 2>&1 && python --version >/dev/null 2>&1; then
  PY_CMD="python"
fi

if [[ -n "$PY_CMD" ]]; then
  exec "$PY_CMD" - "$MODE" "$REPO" "$PR_NUMBER" <<'PY_EOF'
import json, re, subprocess, sys
from urllib.parse import quote

mode, repo, pr_str = sys.argv[1], sys.argv[2], sys.argv[3]
pr_int = int(pr_str)

def fail(reason):
    sys.stdout.write(f"GH_VERIFY_ERROR: {reason}\n")
    sys.exit(1)

def safe_text(val, field):
    s = "" if val is None else str(val)
    if any(ord(c) < 32 or ord(c) == 127 for c in s):
        fail(f"control_chars_in_response({field})")
    return s

def sort_unique(items):
    return sorted({x for x in items if x})

def gh_api(args):
    try:
        r = subprocess.run(["gh", "api"] + args, capture_output=True, text=True)
    except OSError:
        fail("gh_cli_unavailable")
    return r.returncode, r.stdout or "", r.stderr or ""

def has_http(rc, out, err, code):
    txt = f"{err}\n{out}"
    return bool(re.search(rf"\bHTTP\s+{code}\b", txt, re.I) or re.search(rf'"status"\s*:\s*"{code}"', txt, re.I))

def parse_json(raw, ctx):
    if not raw or not raw.strip():
        fail(f"empty_json({ctx})")
    try:
        return json.loads(raw)
    except Exception:
        fail(f"invalid_json({ctx})")

def flatten_pages(parsed):
    if not isinstance(parsed, list):
        return [] if parsed is None else [parsed]
    out = []
    for el in parsed:
        if isinstance(el, list):
            for sub in el:
                if sub is not None:
                    out.append(sub)
        elif el is not None:
            out.append(el)
    return out

rc, out, err = gh_api([f"repos/{repo}/pulls/{pr_str}"])
if rc != 0:
    if has_http(rc, out, err, 404): fail("pr_not_found")
    if has_http(rc, out, err, 401): fail("github_auth_failed")
    if has_http(rc, out, err, 403): fail("github_access_denied")
    fail("pr_query_failed")
pr_obj = parse_json(out, "pull")
if not isinstance(pr_obj, dict) or pr_obj.get("number") != pr_int:
    fail("pr_number_mismatch")

base_obj = pr_obj.get("base") or {}
head_obj = pr_obj.get("head") or {}
base_repo_obj = base_obj.get("repo") or {}
head_repo_obj = head_obj.get("repo")
user_obj = pr_obj.get("user") or {}

base_repo_full = safe_text(base_repo_obj.get("full_name"), "base_repo").strip()
if not base_repo_full or base_repo_full.lower() != repo.lower():
    fail("cross_repo_mismatch")
default_branch = safe_text(base_repo_obj.get("default_branch"), "default_branch").strip()
if not default_branch:
    fail("missing_default_branch")

base_ref = safe_text(base_obj.get("ref"), "base_ref").strip()
pr_base_sha = safe_text(base_obj.get("sha"), "pr_base_sha").strip().lower()
head_ref = safe_text(head_obj.get("ref"), "head_ref").strip()
head_sha = safe_text(head_obj.get("sha"), "head_sha").strip().lower()
if not base_ref or not re.fullmatch(r"[0-9a-f]{40}", pr_base_sha) or not re.fullmatch(r"[0-9a-f]{40}", head_sha):
    fail("incomplete_pr_refs")

pr_state = safe_text(pr_obj.get("state"), "pr_state").strip().upper()
if pr_state not in ("OPEN", "CLOSED"):
    fail(f"invalid_pr_state({pr_state})")

pr_merged = pr_obj.get("merged") is True
merged_at = safe_text(pr_obj.get("merged_at"), "merged_at").strip() if pr_obj.get("merged_at") else "none"
merge_commit_sha = safe_text(pr_obj.get("merge_commit_sha"), "merge_commit_sha").strip().lower() if pr_obj.get("merge_commit_sha") else "none"
if merge_commit_sha != "none" and not re.fullmatch(r"[0-9a-f]{40}", merge_commit_sha):
    fail("invalid_merge_commit_sha")

if mode == "post-merge":
    pr_commits = int(pr_obj.get("commits") or 0)
    live_target_sha = "none"
    compare_status = "not_merged"
    compare_behind = -1
    if pr_merged and re.fullmatch(r"[0-9a-f]{40}", merge_commit_sha):
        enc_base = quote(base_ref, safe="")
        rc_b, out_b, err_b = gh_api([f"repos/{base_repo_full}/branches/{enc_base}"])
        if rc_b != 0:
            if has_http(rc_b, out_b, err_b, 404):
                compare_status = "target_branch_missing"
            else:
                fail("target_branch_query_failed")
        else:
            br_obj = parse_json(out_b, "target_branch")
            lt_sha = safe_text((br_obj.get("commit") or {}).get("sha"), "live_target_sha").strip().lower()
            if not re.fullmatch(r"[0-9a-f]{40}", lt_sha):
                fail("invalid_live_target_sha")
            live_target_sha = lt_sha
            rc_c, out_c, err_c = gh_api([f"repos/{base_repo_full}/compare/{merge_commit_sha}...{live_target_sha}"])
            if rc_c != 0:
                fail("compare_query_failed")
            cmp_obj = parse_json(out_c, "compare")
            c_stat = safe_text(cmp_obj.get("status"), "compare_status").strip().lower()
            if c_stat not in ("identical", "ahead", "behind", "diverged"):
                fail(f"invalid_compare_status({c_stat})")
            compare_status = c_stat
            compare_behind = int(cmp_obj["behind_by"]) if isinstance(cmp_obj.get("behind_by"), int) else -1
    for ln in [
        "schema=b3-gh-verify-v1",
        "mode=post-merge",
        f"repo={repo}",
        f"pr_number={pr_int}",
        f"base_repo={base_repo_full}",
        f"default_branch={default_branch}",
        f"pr_state={pr_state}",
        f"pr_merged={'true' if pr_merged else 'false'}",
        f"merged_at={merged_at}",
        f"merge_commit_sha={merge_commit_sha}",
        f"base_ref={base_ref}",
        f"head_sha={head_sha}",
        f"pr_commits={pr_commits}",
        f"live_target_sha={live_target_sha}",
        f"compare_status={compare_status}",
        f"compare_behind_by={compare_behind}",
    ]:
        print(ln)
    sys.exit(0)

head_repo_full = safe_text(head_repo_obj.get("full_name"), "head_repo").strip() if isinstance(head_repo_obj, dict) and head_repo_obj.get("full_name") else "none"
same_repo = head_repo_full != "none" and head_repo_full.lower() == base_repo_full.lower()
pr_draft = pr_obj.get("draft") is True
pr_author = safe_text(user_obj.get("login"), "pr_author").strip()
if not pr_author:
    fail("missing_pr_author")

mergeable_val = pr_obj.get("mergeable")
mergeable_str = ("true" if mergeable_val else "false") if isinstance(mergeable_val, bool) else "unknown"
mergeable_state = safe_text(pr_obj.get("mergeable_state"), "mergeable_state").strip().lower() if pr_obj.get("mergeable_state") else "unknown"

enc_base = quote(base_ref, safe="")
rc_b, out_b, err_b = gh_api([f"repos/{base_repo_full}/branches/{enc_base}"])
if rc_b != 0:
    fail("target_branch_query_failed")
base_br = parse_json(out_b, "target_branch")
live_target_sha = safe_text((base_br.get("commit") or {}).get("sha"), "live_target_sha").strip().lower()
if not re.fullmatch(r"[0-9a-f]{40}", live_target_sha):
    fail("invalid_live_target_sha")
branch_protected = base_br.get("protected") is True

req_checks = []
req_reviews = 0
req_codeowners = False

prot_sum = base_br.get("protection") or {}
rsc = prot_sum.get("required_status_checks") or {}
for ctx in (rsc.get("contexts") or []):
    if isinstance(ctx, str) and ctx.strip():
        req_checks.append(safe_text(ctx.strip(), "required_check"))
for chk in (rsc.get("checks") or []):
    if isinstance(chk, dict) and isinstance(chk.get("context"), str) and chk["context"].strip():
        req_checks.append(safe_text(chk["context"].strip(), "required_check"))

policy_authority_ref = default_branch
policy_authority_sha = live_target_sha
if default_branch != base_ref:
    enc_def = quote(default_branch, safe="")
    rc_d, out_d, err_d = gh_api([f"repos/{base_repo_full}/branches/{enc_def}"])
    if rc_d != 0:
        fail("policy_authority_query_failed")
    def_br = parse_json(out_d, "default_branch")
    policy_authority_sha = safe_text((def_br.get("commit") or {}).get("sha"), "policy_authority_sha").strip().lower()
    if not re.fullmatch(r"[0-9a-f]{40}", policy_authority_sha):
        fail("invalid_policy_authority_sha")

rc_r, out_r, err_r = gh_api(["--paginate", "--slurp", f"repos/{base_repo_full}/rules/branches/{enc_base}?per_page=100"])
if rc_r == 0:
    rules_arr = flatten_pages(parse_json(out_r, "branch_rules"))
    for r in rules_arr:
        if not isinstance(r, dict): continue
        p = r.get("parameters") or {}
        if r.get("type") == "pull_request":
            cnt = p.get("required_approving_review_count")
            if isinstance(cnt, int) and cnt > req_reviews: req_reviews = cnt
            if p.get("require_code_owner_review") is True: req_codeowners = True
        elif r.get("type") == "required_status_checks":
            for rc_item in (p.get("required_status_checks") or []):
                if isinstance(rc_item, dict) and isinstance(rc_item.get("context"), str) and rc_item["context"].strip():
                    req_checks.append(safe_text(rc_item["context"].strip(), "ruleset_check"))
elif not has_http(rc_r, out_r, err_r, 404):
    fail("branch_rules_unavailable")

branch_protection_readable = True
if branch_protected:
    rc_p, out_p, err_p = gh_api([f"repos/{base_repo_full}/branches/{enc_base}/protection"])
    if rc_p == 0:
        p_obj = parse_json(out_p, "branch_protection")
        p_rsc = p_obj.get("required_status_checks") or {}
        for ctx in (p_rsc.get("contexts") or []):
            if isinstance(ctx, str) and ctx.strip(): req_checks.append(safe_text(ctx.strip(), "prot_check"))
        for chk in (p_rsc.get("checks") or []):
            if isinstance(chk, dict) and isinstance(chk.get("context"), str) and chk["context"].strip():
                req_checks.append(safe_text(chk["context"].strip(), "prot_check"))
        p_rev = p_obj.get("required_pull_request_reviews") or {}
        cnt = p_rev.get("required_approving_review_count")
        if isinstance(cnt, int) and cnt > req_reviews: req_reviews = cnt
        if p_rev.get("require_code_owner_reviews") is True: req_codeowners = True
    elif has_http(rc_p, out_p, err_p, 403) or has_http(rc_p, out_p, err_p, 404):
        branch_protection_readable = False
    else:
        fail("branch_protection_unavailable")

req_checks_arr = sort_unique(req_checks)

rc_f, out_f, err_f = gh_api(["--paginate", "--slurp", f"repos/{base_repo_full}/pulls/{pr_str}/files?per_page=100"])
if rc_f != 0:
    fail("pr_files_query_failed")
pr_changed = []
for fi in flatten_pages(parse_json(out_f, "pr_files")):
    if not isinstance(fi, dict): continue
    if isinstance(fi.get("filename"), str) and fi["filename"].strip():
        pr_changed.append(safe_text(fi["filename"].strip().replace("\\", "/"), "pr_file"))
    if isinstance(fi.get("previous_filename"), str) and fi["previous_filename"].strip():
        pr_changed.append(safe_text(fi["previous_filename"].strip().replace("\\", "/"), "pr_prev_file"))
pr_changed_sorted = sort_unique(pr_changed)

rc_rv, out_rv, err_rv = gh_api(["--paginate", "--slurp", f"repos/{base_repo_full}/pulls/{pr_str}/reviews?per_page=100"])
if rc_rv != 0:
    fail("pr_reviews_query_failed")
latest_by_rev = {}
for rv in flatten_pages(parse_json(out_rv, "pr_reviews")):
    if not isinstance(rv, dict): continue
    st = safe_text(rv.get("state"), "review_state").strip().upper()
    if st not in ("APPROVED", "CHANGES_REQUESTED", "DISMISSED"): continue
    rv_user = rv.get("user") or {}
    login = safe_text(rv_user.get("login"), "review_user").strip()
    if not login: continue
    user_type = safe_text(rv_user.get("type"), "review_user_type").strip()
    assoc = safe_text(rv.get("author_association"), "review_author_association").strip().upper()
    commit = safe_text(rv.get("commit_id"), "review_commit").strip().lower() if rv.get("commit_id") else ""
    latest_by_rev[login.lower()] = (login, st, commit, user_type, assoc)

author_low = pr_author.lower()
allowed_assocs = {"OWNER", "MEMBER", "COLLABORATOR"}
changes_req = 0
self_appr = 0
unauth_appr = 0
stale_indep = 0
indep_revs = []
for k, (login, st, commit, user_type, assoc) in latest_by_rev.items():
    if st == "CHANGES_REQUESTED":
        changes_req += 1
    elif st == "APPROVED":
        if k == author_low:
            if commit == head_sha: self_appr += 1
        elif user_type != "User" or assoc not in allowed_assocs:
            if commit == head_sha: unauth_appr += 1
        elif commit == head_sha:
            indep_revs.append(login)
        else:
            stale_indep += 1
indep_revs_arr = sort_unique(indep_revs)
indep_cnt = len(indep_revs_arr)

gh_rev_status = "PENDING"
if changes_req > 0: gh_rev_status = "BLOCKED"
elif indep_cnt > 0 and indep_cnt >= req_reviews: gh_rev_status = "PASS"
elif indep_cnt == 0 and self_appr > 0: gh_rev_status = "SELF_REVIEW_ONLY"
elif indep_cnt == 0 and unauth_appr > 0: gh_rev_status = "UNAUTHORIZED_ONLY"
elif indep_cnt == 0 and stale_indep > 0: gh_rev_status = "STALE"

rc_cr, out_cr, err_cr = gh_api(["--paginate", "--slurp", f"repos/{base_repo_full}/commits/{head_sha}/check-runs?per_page=100"])
if rc_cr != 0:
    fail("check_runs_query_failed")
cr_raw = parse_json(out_cr, "check_runs")
cr_pages = cr_raw if isinstance(cr_raw, list) else [cr_raw]
latest_checks = {}
for pg in cr_pages:
    if not isinstance(pg, dict) or not isinstance(pg.get("check_runs"), list): continue
    for run in pg["check_runs"]:
        if not isinstance(run, dict): continue
        if run.get("head_sha") and str(run["head_sha"]).strip().lower() != head_sha:
            fail("check_run_sha_mismatch")
        name = safe_text(run.get("name"), "check_name").strip()
        if not name: continue
        app_obj = run.get("app") if isinstance(run.get("app"), dict) else {}
        app_id = str(app_obj["id"]) if app_obj.get("id") is not None else "0"
        ckey = f"{app_id}\0{name}"
        rid = int(run.get("id") or 0)
        st = safe_text(run.get("status"), "check_status").strip().lower()
        conc = safe_text(run.get("conclusion"), "check_conclusion").strip().lower() if run.get("conclusion") else ""
        if ckey not in latest_checks or rid >= latest_checks[ckey][1]:
            latest_checks[ckey] = (name, rid, st, conc)

rc_st, out_st, err_st = gh_api(["--paginate", "--slurp", f"repos/{base_repo_full}/commits/{head_sha}/status?per_page=100"])
if rc_st != 0:
    fail("commit_status_query_failed")
st_raw = parse_json(out_st, "commit_status")
st_pages = st_raw if isinstance(st_raw, list) else [st_raw]
latest_statuses = {}
combined_status_failed = False
combined_status_pending = False
for st_obj in st_pages:
    if not isinstance(st_obj, dict): continue
    if st_obj.get("sha") and str(st_obj["sha"]).strip().lower() != head_sha:
        fail("commit_status_sha_mismatch")
    st_total = st_obj.get("total_count") if isinstance(st_obj.get("total_count"), int) else 0
    st_top = safe_text(st_obj.get("state"), "status_top_state").strip().lower()
    if st_total > 0:
        if st_top in ("failure", "error"): combined_status_failed = True
        elif st_top == "pending": combined_status_pending = True
    for st_item in (st_obj.get("statuses") or []):
        if not isinstance(st_item, dict): continue
        ctx = safe_text(st_item.get("context"), "status_context").strip()
        if not ctx or ctx in latest_statuses: continue
        latest_statuses[ctx] = safe_text(st_item.get("state"), "status_state").strip().lower()

has_failed = combined_status_failed
has_pending = False
passed = set()
failed_names = set()
total_seen = 0
success_cnt = 0
for name, _, st, conc in latest_checks.values():
    total_seen += 1
    if st != "completed":
        has_pending = True
        failed_names.add(name)
    elif conc == "success":
        success_cnt += 1
        passed.add(name)
    elif conc in ("neutral", "skipped"):
        passed.add(name)
    else:
        has_failed = True
        failed_names.add(name)
for ctx, st in latest_statuses.items():
    total_seen += 1
    if st == "success":
        success_cnt += 1
        passed.add(ctx)
    elif st == "pending":
        has_pending = True
        failed_names.add(ctx)
    else:
        has_failed = True
        failed_names.add(ctx)
if combined_status_pending and not latest_statuses:
    has_pending = True

missing_req = sort_unique([rc_n for rc_n in req_checks_arr if rc_n not in passed or rc_n in failed_names])
if has_failed: gh_ci = "FAIL"
elif has_pending: gh_ci = "PENDING"
elif missing_req: gh_ci = "MISSING_REQUIRED"
elif total_seen == 0 or success_cnt == 0: gh_ci = "UNKNOWN"
else: gh_ci = "PASS"

for ln in [
    "schema=b3-gh-verify-v1",
    "mode=pre-merge",
    f"repo={repo}",
    f"pr_number={pr_str}",
    f"base_repo={base_repo_full}",
    f"head_repo={head_repo_full}",
    f"same_repo={'true' if same_repo else 'false'}",
    f"default_branch={default_branch}",
    f"pr_state={pr_state}",
    f"pr_merged={'true' if pr_merged else 'false'}",
    f"pr_draft={'true' if pr_draft else 'false'}",
    f"pr_author={pr_author}",
    f"base_ref={base_ref}",
    f"pr_base_sha={pr_base_sha}",
    f"live_target_sha={live_target_sha}",
    f"head_ref={head_ref}",
    f"head_sha={head_sha}",
    f"policy_authority_ref={policy_authority_ref}",
    f"policy_authority_sha={policy_authority_sha}",
    f"mergeable={mergeable_str}",
    f"mergeable_state={mergeable_state}",
    f"branch_protected={'true' if branch_protected else 'false'}",
    f"branch_protection_readable={'true' if branch_protection_readable else 'false'}",
    f"required_approving_reviews={req_reviews}",
    f"require_codeowners={'true' if req_codeowners else 'false'}",
    f"required_checks={','.join(req_checks_arr) if req_checks_arr else 'none'}",
    f"missing_required_checks={','.join(missing_req) if missing_req else 'none'}",
    f"gh_ci_status={gh_ci}",
    f"gh_review_status={gh_rev_status}",
    f"independent_approved_count={indep_cnt}",
    f"stale_independent_approved_count={stale_indep}",
    f"self_approved_count={self_appr}",
    f"unauthorized_approved_count={unauth_appr}",
    f"changes_requested_count={changes_req}",
    f"independent_reviewers={','.join(indep_revs_arr) if indep_revs_arr else 'none'}",
]:
    print(ln)
for cf in pr_changed_sorted:
    print(f"pr_changed_file={cf}")
sys.exit(0)
PY_EOF
fi

echo "GH_VERIFY_ERROR: json_runtime_unavailable"
exit 1
