#!/usr/bin/env node
// Shared read-only GitHub REST verification helper for b3-guard merge-policy-check.
// Queries PR metadata, branch SHAs, changed files, check-runs/statuses, and post-merge compare via `gh api`.
// Exit codes: 0 = verified metadata emitted, 1 = GH_VERIFY_ERROR (invalid input/404/corrupt), 2 = GH_VERIFY_UNAVAILABLE (missing gh/auth/5xx/network).

import { spawnSync } from "node:child_process";
import {
  execGh,
  hasControlChars,
  parseGitHubRemoteSlug,
  parseJsonStrict,
  resolveBashBinary,
  resolveGhBinary,
  sortOrdinal,
  validatePrNumber,
  validateRepoSlug,
} from "./b3-gh-exec.mjs";

function failError(reason) {
  process.stdout.write(`GH_VERIFY_ERROR: ${reason}\n`);
  process.exit(1);
}

function failUnavailable(reason) {
  process.stdout.write(`GH_VERIFY_UNAVAILABLE: ${reason}\n`);
  process.exit(2);
}

function safeText(val, field) {
  const s = val == null ? "" : String(val);
  if (hasControlChars(s)) {
    failError(`control_chars_in_response(${field})`);
  }
  return s;
}

function sortUnique(arr) {
  const set = new Set();
  for (const x of arr) {
    if (x) set.add(x);
  }
  return sortOrdinal(Array.from(set));
}

let mode = "";
let repoArg = "";
let repoRootArg = "";
let hasRepoRoot = false;
let prArg = "";
let ghBinArg = "";
let bashBinArg = "";

const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  const next = () => {
    if (i + 1 >= argv.length) failError(`missing_value(${a})`);
    return argv[++i];
  };
  switch (a) {
    case "--mode":
    case "-Mode":
      mode = next();
      break;
    case "--repo":
    case "-Repo":
      repoArg = next();
      break;
    case "--repo-root":
    case "-RepoRoot":
      repoRootArg = next();
      hasRepoRoot = true;
      break;
    case "--pr-number":
    case "-PrNumber":
      prArg = next();
      break;
    case "--gh-bin":
    case "-GhBin":
      ghBinArg = next();
      break;
    case "--bash-bin":
    case "-BashBin":
      bashBinArg = next();
      break;
    default:
      failError(`unknown_option(${a})`);
  }
}

const modeTrim = mode.trim();
if (modeTrim !== "pre-merge" && modeTrim !== "post-merge") {
  failError("invalid_mode");
}

const prCheck = validatePrNumber(prArg);
if (!prCheck.ok) {
  failError("invalid_pr_number");
}
const prTrim = prCheck.str;
const prInt = prCheck.num;

const repoTrim = repoArg.trim();
if (repoTrim) {
  const repoCheck = validateRepoSlug(repoTrim);
  if (!repoCheck.ok) {
    failError("invalid_repo");
  }
}

let resolvedRepo = repoTrim;
if (hasRepoRoot || !repoTrim) {
  const rootDir = (hasRepoRoot ? repoRootArg.trim() : ".") || ".";
  const gitRes = spawnSync("git", ["-C", rootDir, "remote", "get-url", "origin"], {
    encoding: "utf8",
    maxBuffer: 4 * 1024 * 1024,
  });
  if (gitRes.error) {
    failError("git_unavailable");
  }
  if (gitRes.status !== 0) {
    failError("origin_remote_missing");
  }
  const originSlug = parseGitHubRemoteSlug(gitRes.stdout || "");
  if (!originSlug) {
    failError("origin_remote_not_github");
  }
  if (repoTrim && repoTrim.toLowerCase() !== originSlug.toLowerCase()) {
    failError("repo_mismatch");
  }
  resolvedRepo = originSlug;
}

const ghBin = resolveGhBinary(ghBinArg);
if (!ghBin) {
  failUnavailable("gh_cli_unavailable");
}
const isWin = process.platform === "win32";
const bashBin = isWin && !/\.(exe|com|cmd|bat)$/i.test(ghBin) ? resolveBashBinary(bashBinArg) : "";
if (isWin && !/\.(exe|com|cmd|bat)$/i.test(ghBin) && !bashBin) {
  failUnavailable("gh_cli_unavailable");
}

function invokeGhApi(args) {
  const r = execGh(["api", ...args], {
    ghBin,
    bashBin,
    maxBuffer: 32 * 1024 * 1024,
  });
  if (!r.ok) {
    failUnavailable("gh_cli_unavailable");
  }
  return {
    code: r.status,
    stdout: r.stdout,
    stderr: r.stderr,
  };
}

function hasHttp(res, code) {
  const txt = `${res.stderr}\n${res.stdout}`;
  const re1 = new RegExp(`\\bHTTP\\s+${code}\\b`, "i");
  const re2 = new RegExp(`"status"\\s*:\\s*"?${code}"?`, "i");
  return re1.test(txt) || re2.test(txt);
}

function failOnApiFailure(res, endpointLabel, allow404Reason = "") {
  const txt = `${res.stderr}\n${res.stdout}`;
  if (allow404Reason && hasHttp(res, 404)) {
    failError(allow404Reason);
  }
  if (hasHttp(res, 401)) failUnavailable("github_auth_failed");
  if (hasHttp(res, 403)) failUnavailable("github_access_denied");
  if (hasHttp(res, 429)) failUnavailable("github_rate_limited");
  if (/\bHTTP\s+5\d\d\b/i.test(txt) || /"status"\s*:\s*"?5\d\d"?/i.test(txt)) {
    failUnavailable("github_http_5xx");
  }
  if (
    /not logged into|gh auth login|bad credentials|authentication|error connecting|dial tcp|i\/o timeout|timed out|connection refused|connection reset|could not resolve|no such host|network is unreachable|tls handshake/i.test(
      txt
    )
  ) {
    failUnavailable("github_network_or_auth_error");
  }
  if (hasHttp(res, 404)) {
    failError(`${endpointLabel}_not_found`);
  }
  failError(`${endpointLabel}_query_failed`);
}

function parseJson(raw, ctx) {
  const parsed = parseJsonStrict(raw);
  if (!parsed.ok) {
    failError(`${parsed.reason}(${ctx})`);
  }
  return parsed.value;
}

function resolvePolicyAuthoritySha(baseRepoFull, defaultBranch, baseRef, liveTargetSha) {
  if (defaultBranch === baseRef) {
    return liveTargetSha;
  }
  const encDef = encodeURIComponent(defaultBranch);
  const defBrRes = invokeGhApi([`repos/${baseRepoFull}/branches/${encDef}`]);
  if (defBrRes.code !== 0) {
    failOnApiFailure(defBrRes, "policy_authority");
  }
  const defBrObj = parseJson(defBrRes.stdout, "default_branch");
  const sha = safeText((defBrObj.commit || {}).sha, "policy_authority_sha").trim().toLowerCase();
  if (!/^[0-9a-f]{40}$/.test(sha)) failError("invalid_policy_authority_sha");
  return sha;
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

const prRes = invokeGhApi([`repos/${resolvedRepo}/pulls/${prTrim}`]);
if (prRes.code !== 0) {
  failOnApiFailure(prRes, "pr", "pr_not_found");
}
const prObj = parseJson(prRes.stdout, "pull");
if (!prObj || typeof prObj !== "object" || Number(prObj.number) !== prInt) {
  failError("pr_number_mismatch");
}

const baseObj = prObj.base || {};
const headObj = prObj.head || {};
const baseRepoObj = baseObj.repo || {};
const headRepoObj = headObj.repo || null;

const baseRepoFull = safeText(baseRepoObj.full_name, "base_repo").trim();
if (!baseRepoFull || baseRepoFull.toLowerCase() !== resolvedRepo.toLowerCase()) {
  failError("cross_repo_mismatch");
}
const defaultBranch = safeText(baseRepoObj.default_branch, "default_branch").trim();
if (!defaultBranch) failError("missing_default_branch");

const baseRef = safeText(baseObj.ref, "base_ref").trim();
const prBaseSha = safeText(baseObj.sha, "pr_base_sha").trim().toLowerCase();
const headRef = safeText(headObj.ref, "head_ref").trim();
const headSha = safeText(headObj.sha, "head_sha").trim().toLowerCase();
if (!baseRef || !/^[0-9a-f]{40}$/.test(prBaseSha) || !/^[0-9a-f]{40}$/.test(headSha)) {
  failError("incomplete_pr_refs");
}

const prState = safeText(prObj.state, "pr_state").trim().toUpperCase();
if (prState !== "OPEN" && prState !== "CLOSED") {
  failError(`invalid_pr_state(${prState})`);
}

const prMerged = prObj.merged === true;
const mergedAt = prObj.merged_at ? safeText(prObj.merged_at, "merged_at").trim() : "none";
const mergeCommitSha = prObj.merge_commit_sha
  ? safeText(prObj.merge_commit_sha, "merge_commit_sha").trim().toLowerCase()
  : "none";
if (mergeCommitSha !== "none" && !/^[0-9a-f]{40}$/.test(mergeCommitSha)) {
  failError("invalid_merge_commit_sha");
}

if (modeTrim === "post-merge") {
  const prCommits = typeof prObj.commits === "number" ? prObj.commits : 0;
  let liveTargetSha = "none";
  let compareStatus = "not_merged";
  let compareBehind = -1;
  const policyAuthorityRef = defaultBranch;
  let policyAuthoritySha = "none";

  if (prMerged && /^[0-9a-f]{40}$/.test(mergeCommitSha)) {
    const encBase = encodeURIComponent(baseRef);
    const brRes = invokeGhApi([`repos/${baseRepoFull}/branches/${encBase}`]);
    if (brRes.code !== 0) {
      if (hasHttp(brRes, 404)) {
        compareStatus = "target_branch_missing";
      } else {
        failOnApiFailure(brRes, "target_branch");
      }
    } else {
      const brObj = parseJson(brRes.stdout, "target_branch");
      const ltSha = safeText((brObj.commit || {}).sha, "live_target_sha").trim().toLowerCase();
      if (!/^[0-9a-f]{40}$/.test(ltSha)) failError("invalid_live_target_sha");
      liveTargetSha = ltSha;

      const cmpRes = invokeGhApi([`repos/${baseRepoFull}/compare/${mergeCommitSha}...${liveTargetSha}`]);
      if (cmpRes.code !== 0) {
        failOnApiFailure(cmpRes, "compare");
      }
      const cmpObj = parseJson(cmpRes.stdout, "compare");
      const cStat = safeText(cmpObj.status, "compare_status").trim().toLowerCase();
      if (!["identical", "ahead", "behind", "diverged"].includes(cStat)) {
        failError(`invalid_compare_status(${cStat})`);
      }
      compareStatus = cStat;
      compareBehind = typeof cmpObj.behind_by === "number" ? cmpObj.behind_by : -1;
    }

    policyAuthoritySha = resolvePolicyAuthoritySha(baseRepoFull, defaultBranch, baseRef, liveTargetSha);
  }

  const postLines = [
    "schema=b3-gh-verify-v2",
    "mode=post-merge",
    `repo=${resolvedRepo}`,
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
    `policy_authority_ref=${policyAuthorityRef}`,
    `policy_authority_sha=${policyAuthoritySha}`,
    `compare_status=${compareStatus}`,
    `compare_behind_by=${compareBehind}`,
  ];
  process.stdout.write(postLines.join("\n") + "\n");
  process.exit(0);
}

// --- pre-merge mode ---
const headRepoFull =
  headRepoObj && headRepoObj.full_name
    ? safeText(headRepoObj.full_name, "head_repo").trim()
    : "none";
const sameRepo = headRepoFull !== "none" && headRepoFull.toLowerCase() === baseRepoFull.toLowerCase();
const prDraft = prObj.draft === true;

const mergeableStr =
  typeof prObj.mergeable === "boolean" ? (prObj.mergeable ? "true" : "false") : "unknown";
const mergeableState = prObj.mergeable_state
  ? safeText(prObj.mergeable_state, "mergeable_state").trim().toLowerCase()
  : "unknown";

const encBaseRef = encodeURIComponent(baseRef);
const baseBrRes = invokeGhApi([`repos/${baseRepoFull}/branches/${encBaseRef}`]);
if (baseBrRes.code !== 0) {
  failOnApiFailure(baseBrRes, "target_branch");
}
const baseBrObj = parseJson(baseBrRes.stdout, "target_branch");
const liveTargetSha = safeText((baseBrObj.commit || {}).sha, "live_target_sha").trim().toLowerCase();
if (!/^[0-9a-f]{40}$/.test(liveTargetSha)) failError("invalid_live_target_sha");

const policyAuthorityRef = defaultBranch;
const policyAuthoritySha = resolvePolicyAuthoritySha(baseRepoFull, defaultBranch, baseRef, liveTargetSha);

const filesRes = invokeGhApi(["--paginate", "--slurp", `repos/${baseRepoFull}/pulls/${prTrim}/files?per_page=100`]);
if (filesRes.code !== 0) {
  failOnApiFailure(filesRes, "pr_files");
}
const fileItems = flattenPages(parseJson(filesRes.stdout, "pr_files"));
const prChangedList = [];
for (const fi of fileItems) {
  if (!fi || typeof fi !== "object") continue;
  if (typeof fi.filename === "string" && fi.filename.length > 0) {
    prChangedList.push(safeText(fi.filename, "pr_file"));
  }
  if (typeof fi.previous_filename === "string" && fi.previous_filename.length > 0) {
    prChangedList.push(safeText(fi.previous_filename, "pr_prev_file"));
  }
}
const prChangedSorted = sortUnique(prChangedList);

const crRes = invokeGhApi(["--paginate", "--slurp", `repos/${baseRepoFull}/commits/${headSha}/check-runs?per_page=100`]);
if (crRes.code !== 0) {
  failOnApiFailure(crRes, "check_runs");
}
const crRaw = parseJson(crRes.stdout, "check_runs");
const crPages = Array.isArray(crRaw) ? crRaw : [crRaw];
const latestChecks = new Map();
for (const pg of crPages) {
  if (!pg || !Array.isArray(pg.check_runs)) continue;
  for (const run of pg.check_runs) {
    if (!run || typeof run !== "object") continue;
    if (run.head_sha && String(run.head_sha).trim().toLowerCase() !== headSha) {
      failError("check_run_sha_mismatch");
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

const stRes = invokeGhApi(["--paginate", "--slurp", `repos/${baseRepoFull}/commits/${headSha}/status?per_page=100`]);
if (stRes.code !== 0) {
  failOnApiFailure(stRes, "commit_status");
}
const stRaw = parseJson(stRes.stdout, "commit_status");
const stPages = Array.isArray(stRaw) ? stRaw : [stRaw];
const latestStatuses = new Map();
let combinedStatusFailed = false;
let combinedStatusPending = false;
for (const stObj of stPages) {
  if (!stObj || typeof stObj !== "object") continue;
  if (stObj.sha && String(stObj.sha).trim().toLowerCase() !== headSha) {
    failError("commit_status_sha_mismatch");
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
let totalChecksSeen = 0;
let successCount = 0;

for (const c of latestChecks.values()) {
  totalChecksSeen++;
  if (c.status !== "completed") {
    hasPending = true;
  } else if (c.conclusion === "success") {
    successCount++;
  } else if (c.conclusion !== "neutral" && c.conclusion !== "skipped") {
    hasFailed = true;
  }
}
for (const st of latestStatuses.values()) {
  totalChecksSeen++;
  if (st === "success") {
    successCount++;
  } else if (st === "pending") {
    hasPending = true;
  } else {
    hasFailed = true;
  }
}
if (combinedStatusPending && latestStatuses.size === 0) {
  hasPending = true;
}

let ghCiStatus = "PASS";
if (hasFailed) {
  ghCiStatus = "FAIL";
} else if (hasPending) {
  ghCiStatus = "PENDING";
} else if (totalChecksSeen === 0 || successCount === 0) {
  ghCiStatus = "UNKNOWN";
}

const outLines = [
  "schema=b3-gh-verify-v2",
  "mode=pre-merge",
  `repo=${resolvedRepo}`,
  `pr_number=${prTrim}`,
  `base_repo=${baseRepoFull}`,
  `head_repo=${headRepoFull}`,
  `same_repo=${sameRepo ? "true" : "false"}`,
  `default_branch=${defaultBranch}`,
  `pr_state=${prState}`,
  `pr_merged=${prMerged ? "true" : "false"}`,
  `pr_draft=${prDraft ? "true" : "false"}`,
  `base_ref=${baseRef}`,
  `pr_base_sha=${prBaseSha}`,
  `live_target_sha=${liveTargetSha}`,
  `head_ref=${headRef}`,
  `head_sha=${headSha}`,
  `policy_authority_ref=${policyAuthorityRef}`,
  `policy_authority_sha=${policyAuthoritySha}`,
  `mergeable=${mergeableStr}`,
  `mergeable_state=${mergeableState}`,
  `gh_ci_status=${ghCiStatus}`,
];
for (const cf of prChangedSorted) {
  outLines.push(`pr_changed_file=${cf}`);
}
process.stdout.write(outLines.join("\n") + "\n");
process.exit(0);
