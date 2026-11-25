#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const EXIT_OK = 0;
const EXIT_ERROR = 1;
const EXIT_BLOCKED = 2;

const MAX_FILE_BYTES = 262144;
const MAX_BODY_CHARS = 65536;
const DEFAULT_MAX_PAGES = 20;
const MAX_ALLOWED_PAGES = 100;

const UNTRUSTED_START = 'BEGIN_UNTRUSTED_PR_DATA';
const UNTRUSTED_END = 'END_UNTRUSTED_PR_DATA';

const REPO_RE = /^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/;
const PR_RE = /^[1-9][0-9]*$/;
const SHA_RE = /^[0-9a-fA-F]{40}$/;
const ID_RE = /^[A-Za-z0-9_=-]{1,128}$/;
const KEY_RE = /^[A-Za-z0-9._:-]{4,80}$/;
const SAFE_GH_ARG_RE = /^[A-Za-z0-9_./:?=&-]+$/;

const ALLOWED_SEVERITIES = new Set(['CRITICAL', 'HIGH', 'MEDIUM', 'LOW']);
const ALLOWED_SIDES = new Set(['RIGHT', 'LEFT']);
const ALLOWED_EVENTS = new Set(['COMMENT', 'APPROVE', 'REQUEST_CHANGES']);
const ALLOWED_MODES = new Set(['summary', 'inline', 'both']);
const ALLOWED_TARGET_KINDS = new Set(['review_thread', 'general_comment']);
const ALLOWED_VERIFY_STATUS = new Set(['PASS', 'FAIL', 'INCOMPLETE']);

function emit(payload, code) {
  process.stdout.write(JSON.stringify(payload) + '\n');
  process.exit(code);
}

function fail(status, message, code = EXIT_ERROR, extra = {}) {
  emit({ status, error: message, ...extra }, code);
}

function hasControlChars(str) {
  return /[\x00-\x1F\x7F]/.test(str);
}

function sanitizeUntrustedText(val) {
  let s = val === null || val === undefined ? '' : String(val);
  // Preserve \t (\x09), \n (\x0A), \r (\x0D); strip other ASCII control chars.
  s = s.replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g, '');
  // Strip Unicode bidirectional overrides/isolates and direction marks.
  s = s.replace(/[\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]/g, '');
  // Strip Unicode Tag characters (U+E0000..U+E007F).
  s = s.replace(/[\u{E0000}-\u{E007F}]/gu, '');
  // Neutralize delimiter breakout attempts.
  s = s.replace(/BEGIN_UNTRUSTED_PR_DATA/gi, 'BEGIN_UNTRUSTED_PR_DATA_ESCAPED');
  s = s.replace(/END_UNTRUSTED_PR_DATA/gi, 'END_UNTRUSTED_PR_DATA_ESCAPED');
  return s;
}

function frameUntrustedText(val) {
  return `${UNTRUSTED_START}\n${sanitizeUntrustedText(val)}\n${UNTRUSTED_END}`;
}

function parseArgs(argv) {
  if (argv.length === 0) {
    fail('PR_INVALID_ARGS', 'Missing subcommand (expected: fetch, reply, resolve, comment)', EXIT_ERROR);
  }
  const cmd = argv[0];
  const flags = {};
  const booleanFlags = new Set([
    'include-resolved',
    'include-bodies',
    'authorize-write',
    'authorize-resolve',
    'draft'
  ]);
  const valueFlags = new Set([
    'repo',
    'pr',
    'max-pages',
    'expected-head',
    'target-kind',
    'target-id',
    'body-file',
    'idempotency-key',
    'state-file',
    'thread-id',
    'fix-commit',
    'verify-status',
    'mode',
    'event',
    'summary-file',
    'inline-json',
    'authorize-review-event'
  ]);
  for (let i = 1; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith('--')) {
      fail('PR_INVALID_ARGS', `Unexpected positional argument: ${arg}`, EXIT_ERROR);
    }
    const name = arg.slice(2);
    if (!name) {
      fail('PR_INVALID_ARGS', 'Empty flag name', EXIT_ERROR);
    }
    if (booleanFlags.has(name)) {
      flags[name] = true;
    } else if (valueFlags.has(name)) {
      if (i + 1 >= argv.length) {
        fail('PR_INVALID_ARGS', `Missing value for --${name}`, EXIT_ERROR);
      }
      const val = argv[i + 1];
      if (val.startsWith('--')) {
        fail('PR_INVALID_ARGS', `Missing value for --${name}`, EXIT_ERROR);
      }
      flags[name] = val;
      i += 1;
    } else {
      fail('PR_INVALID_ARGS', `Unknown flag: --${name}`, EXIT_ERROR);
    }
  }
  return { cmd, flags };
}

function validateRepo(repo) {
  if (!repo || hasControlChars(repo) || !REPO_RE.test(repo) || repo.includes('..')) {
    fail('PR_INVALID_ARGS', 'Invalid --repo (expected owner/repo)', EXIT_ERROR);
  }
  const [owner, name] = repo.split('/');
  if (!owner || !name || owner === '.' || name === '.') {
    fail('PR_INVALID_ARGS', 'Invalid --repo segments', EXIT_ERROR);
  }
  return { owner, name, full: `${owner}/${name}` };
}

function validatePr(prStr) {
  if (!prStr || hasControlChars(prStr) || !PR_RE.test(prStr)) {
    fail('PR_INVALID_ARGS', 'Invalid --pr (expected positive integer)', EXIT_ERROR);
  }
  const num = Number.parseInt(prStr, 10);
  if (!Number.isSafeInteger(num) || num <= 0) {
    fail('PR_INVALID_ARGS', 'Invalid --pr value', EXIT_ERROR);
  }
  return num;
}

function validateSha(sha, flagName) {
  if (!sha || hasControlChars(sha) || !SHA_RE.test(sha)) {
    fail('PR_INVALID_ARGS', `Invalid ${flagName} (expected 40-hex commit SHA)`, EXIT_ERROR);
  }
  return sha.toLowerCase();
}

function validateId(id, flagName) {
  if (!id || hasControlChars(id) || !ID_RE.test(id)) {
    fail('PR_INVALID_ARGS', `Invalid ${flagName}`, EXIT_ERROR);
  }
  return id;
}

function validateKey(key) {
  if (key === undefined) return '';
  if (!key || hasControlChars(key) || !KEY_RE.test(key)) {
    fail('PR_INVALID_ARGS', 'Invalid --idempotency-key (expected 4-80 chars of [A-Za-z0-9._:-])', EXIT_ERROR);
  }
  return key;
}

function validateMaxPages(val) {
  if (val === undefined) return DEFAULT_MAX_PAGES;
  if (hasControlChars(val) || !PR_RE.test(val)) {
    fail('PR_INVALID_ARGS', 'Invalid --max-pages', EXIT_ERROR);
  }
  const num = Number.parseInt(val, 10);
  if (num < 1 || num > MAX_ALLOWED_PAGES) {
    fail('PR_INVALID_ARGS', `--max-pages must be between 1 and ${MAX_ALLOWED_PAGES}`, EXIT_ERROR);
  }
  return num;
}

function readSafeInputFile(filePath, flagName, maxBytes = MAX_FILE_BYTES) {
  if (!filePath || hasControlChars(filePath)) {
    fail('PR_INVALID_ARGS', `Invalid ${flagName}`, EXIT_ERROR);
  }
  let st;
  try {
    st = fs.lstatSync(filePath);
  } catch (err) {
    fail('PR_FILE_GUARD', `Cannot access ${flagName}: ${err.code || 'ERR'}`, EXIT_ERROR);
  }
  if (st.isSymbolicLink()) {
    fail('PR_FILE_GUARD', `Symlink rejected for ${flagName}`, EXIT_ERROR);
  }
  if (!st.isFile()) {
    fail('PR_FILE_GUARD', `Regular file required for ${flagName}`, EXIT_ERROR);
  }
  if (st.size > maxBytes) {
    fail('PR_FILE_GUARD', `${flagName} exceeds ${maxBytes} bytes`, EXIT_ERROR);
  }
  return fs.readFileSync(filePath, 'utf8');
}

function validateStateFilePath(stateFile) {
  if (!stateFile) return '';
  if (hasControlChars(stateFile)) {
    fail('PR_INVALID_ARGS', 'Invalid --state-file', EXIT_ERROR);
  }
  const parts = stateFile.split(/[\\/]+/);
  if (parts.includes('..')) {
    fail('PR_FILE_GUARD', 'Path traversal rejected for --state-file', EXIT_ERROR);
  }
  if (fs.existsSync(stateFile)) {
    const st = fs.lstatSync(stateFile);
    if (st.isSymbolicLink() || !st.isFile()) {
      fail('PR_FILE_GUARD', 'Symlink or non-file rejected for --state-file', EXIT_ERROR);
    }
  }
  const parent = path.dirname(path.resolve(stateFile));
  if (fs.existsSync(parent)) {
    const pst = fs.lstatSync(parent);
    if (pst.isSymbolicLink()) {
      fail('PR_FILE_GUARD', 'Symlink parent directory rejected for --state-file', EXIT_ERROR);
    }
  }
  return stateFile;
}

function recordAuditState(stateFile, entry) {
  if (!stateFile) return;
  const dir = path.dirname(path.resolve(stateFile));
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
  let records = [];
  if (fs.existsSync(stateFile)) {
    try {
      const parsed = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
      if (Array.isArray(parsed)) records = parsed;
    } catch {
      records = [];
    }
  }
  records.push({ ...entry, recorded_at_utc: new Date().toISOString() });
  const tmpPath = `${stateFile}.tmp.${process.pid}.${Date.now()}`;
  fs.writeFileSync(tmpPath, JSON.stringify(records, null, 2) + '\n', { encoding: 'utf8', flag: 'wx', mode: 0o600 });
  fs.renameSync(tmpPath, stateFile);
}

let cachedGhPath = null;
function resolveGhBinary() {
  if (cachedGhPath) return cachedGhPath;
  const pathEnv = process.env.PATH || process.env.Path || '';
  const dirs = pathEnv.split(path.delimiter).filter(Boolean);
  const isWin = process.platform === 'win32';
  const names = isWin ? ['gh.exe', 'gh.cmd', 'gh.bat'] : ['gh'];

  for (const dir of dirs) {
    for (const name of names) {
      const candidate = path.join(dir, name);
      try {
        const st = fs.statSync(candidate);
        if (!st.isFile()) continue;
        if (!isWin) {
          fs.accessSync(candidate, fs.constants.X_OK);
        }
        cachedGhPath = candidate;
        return candidate;
      } catch {
        // continue
      }
    }
  }
  fail('PR_API_ERROR', 'gh CLI not found in PATH', EXIT_ERROR);
}

function invokeGh(args, stdinStr = null, options = {}) {
  for (const a of args) {
    if (!SAFE_GH_ARG_RE.test(a)) {
      fail('PR_INVALID_ARGS', `Unsafe gh argument rejected: ${a}`, EXIT_ERROR);
    }
  }
  const ghBin = resolveGhBinary();
  const isWinBatch = process.platform === 'win32' && /\.(cmd|bat)$/i.test(ghBin);
  const spawnOpts = {
    encoding: 'utf8',
    windowsHide: true,
    maxBuffer: 64 * 1024 * 1024
  };
  if (stdinStr !== null) {
    spawnOpts.input = stdinStr;
  }

  let res;
  if (isWinBatch) {
    const comspec = process.env.ComSpec || 'cmd.exe';
    const cmdLine = `"${ghBin}" ${args.map((a) => `"${a}"`).join(' ')}`;
    res = spawnSync(comspec, ['/d', '/s', '/c', `"${cmdLine}"`], { ...spawnOpts, windowsVerbatimArguments: true });
  } else {
    res = spawnSync(ghBin, args, { ...spawnOpts, shell: false });
  }

  if (res.error) {
    fail('PR_API_ERROR', `Failed to invoke gh: ${res.error.message}`, EXIT_ERROR);
  }
  const stdout = (res.stdout || '').trim();
  const stderr = (res.stderr || '').trim();
  if (res.status !== 0) {
    if (options.allowNotFound && /404|Not Found/i.test(`${stderr}\n${stdout}`)) {
      return { notFound: true, data: null };
    }
    fail('PR_API_ERROR', `gh api failed (exit ${res.status}): ${sanitizeUntrustedText(stderr || stdout).slice(0, 300)}`, EXIT_ERROR);
  }
  if (!stdout) {
    return { notFound: false, data: null };
  }
  try {
    return { notFound: false, data: JSON.parse(stdout) };
  } catch {
    fail('PR_API_ERROR', 'gh api returned non-JSON output', EXIT_ERROR);
  }
}

function ghGraphQL(query, variables = {}) {
  const payload = JSON.stringify({ query, variables });
  const { data } = invokeGh(['api', 'graphql', '--input', '-'], payload);
  if (!data || typeof data !== 'object') {
    fail('PR_API_ERROR', 'Empty GraphQL response', EXIT_ERROR);
  }
  if (Array.isArray(data.errors) && data.errors.length > 0) {
    const msg = data.errors.map((e) => e.message || 'GraphQL error').join('; ');
    fail('PR_API_ERROR', `GraphQL error: ${sanitizeUntrustedText(msg).slice(0, 300)}`, EXIT_ERROR);
  }
  if (!data.data) {
    fail('PR_API_ERROR', 'Missing data in GraphQL response', EXIT_ERROR);
  }
  return data.data;
}

function ghRestGet(endpoint, options = {}) {
  return invokeGh(['api', endpoint], null, options);
}

function ghRestPost(endpoint, bodyObj) {
  const payload = JSON.stringify(bodyObj);
  const { data } = invokeGh(['api', endpoint, '--method', 'POST', '--input', '-'], payload);
  return data;
}

function fetchRestPaginated(endpointBase, maxPages) {
  const items = [];
  const sep = endpointBase.includes('?') ? '&' : '?';
  for (let page = 1; page <= maxPages; page += 1) {
    const { data } = ghRestGet(`${endpointBase}${sep}per_page=100&page=${page}`);
    if (!Array.isArray(data)) {
      fail('PR_API_ERROR', `Expected array from ${endpointBase}`, EXIT_ERROR);
    }
    items.push(...data);
    if (data.length < 100) {
      return items;
    }
  }
  fail('PR_PAGINATION_INCOMPLETE', `Pagination reached --max-pages (${maxPages}) on ${endpointBase}`, EXIT_BLOCKED);
}

function fetchPrHeader(owner, repo, prNumber) {
  const query = `
    query($owner: String!, $repo: String!, $pr: Int!) {
      viewer { login }
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $pr) {
          number
          state
          headRefOid
        }
      }
    }
  `;
  const data = ghGraphQL(query, { owner, repo, pr: prNumber });
  const viewer = data.viewer && data.viewer.login ? String(data.viewer.login) : '';
  const pr = data.repository && data.repository.pullRequest;
  if (!pr) {
    fail('PR_TARGET_MISMATCH', `Pull request ${owner}/${repo}#${prNumber} not found`, EXIT_ERROR);
  }
  if (!viewer) {
    fail('PR_API_ERROR', 'Unable to resolve authenticated viewer.login', EXIT_ERROR);
  }
  return {
    viewer,
    state: String(pr.state || ''),
    headSha: String(pr.headRefOid || '').toLowerCase()
  };
}

function fetchAllReviewThreads(owner, repo, prNumber, maxPages, includeBodies) {
  const commentFields = includeBodies ? 'id author { login } body' : 'id author { login }';
  const prBodyField = includeBodies ? 'body' : '';
  const query = `
    query($owner: String!, $repo: String!, $pr: Int!, $cursor: String) {
      viewer { login }
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $pr) {
          number
          state
          headRefOid
          title
          baseRefName
          headRefName
          ${prBodyField}
          reviewThreads(first: 100, after: $cursor) {
            pageInfo { hasNextPage endCursor }
            nodes {
              id
              isResolved
              isOutdated
              path
              line
              originalLine
              comments(first: 100) {
                totalCount
                pageInfo { hasNextPage endCursor }
                nodes { ${commentFields} }
              }
            }
          }
        }
      }
    }
  `;
  const nestedQuery = `
    query($threadId: ID!, $cursor: String) {
      node(id: $threadId) {
        ... on PullRequestReviewThread {
          comments(first: 100, after: $cursor) {
            pageInfo { hasNextPage endCursor }
            nodes { ${commentFields} }
          }
        }
      }
    }
  `;

  let cursor = null;
  let viewer = '';
  let prMeta = null;
  const threads = [];

  for (let page = 1; page <= maxPages; page += 1) {
    const data = ghGraphQL(query, { owner, repo, pr: prNumber, cursor });
    if (!viewer && data.viewer && data.viewer.login) {
      viewer = String(data.viewer.login);
    }
    const pr = data.repository && data.repository.pullRequest;
    if (!pr) {
      fail('PR_TARGET_MISMATCH', `Pull request ${owner}/${repo}#${prNumber} not found`, EXIT_ERROR);
    }
    if (!prMeta) {
      prMeta = {
        number: pr.number,
        state: String(pr.state || ''),
        headSha: String(pr.headRefOid || '').toLowerCase(),
        title: pr.title || '',
        baseRefName: pr.baseRefName || '',
        headRefName: pr.headRefName || '',
        body: includeBodies ? (pr.body || '') : undefined
      };
    }
    const rt = pr.reviewThreads;
    const nodes = (rt && Array.isArray(rt.nodes)) ? rt.nodes : [];
    for (const t of nodes) {
      if (!t || !t.id) continue;
      const commentsConn = t.comments || {};
      const comments = Array.isArray(commentsConn.nodes) ? [...commentsConn.nodes] : [];
      let cInfo = commentsConn.pageInfo || { hasNextPage: false, endCursor: null };
      let nestedPages = 1;
      while (cInfo.hasNextPage) {
        if (nestedPages >= maxPages) {
          fail('PR_PAGINATION_INCOMPLETE', `Nested comment pagination reached --max-pages (${maxPages}) on thread ${t.id}`, EXIT_BLOCKED);
        }
        nestedPages += 1;
        const nData = ghGraphQL(nestedQuery, { threadId: t.id, cursor: cInfo.endCursor });
        const nConn = nData.node && nData.node.comments;
        if (!nConn || !Array.isArray(nConn.nodes)) {
          fail('PR_API_ERROR', `Unexpected nested comment response for thread ${t.id}`, EXIT_ERROR);
        }
        comments.push(...nConn.nodes);
        cInfo = nConn.pageInfo || { hasNextPage: false, endCursor: null };
      }
      threads.push({
        id: String(t.id),
        isResolved: Boolean(t.isResolved),
        isOutdated: Boolean(t.isOutdated),
        path: t.path || '',
        line: t.line ?? t.originalLine ?? null,
        totalCount: commentsConn.totalCount ?? comments.length,
        comments: comments.map((c) => ({
          id: String(c.id || ''),
          author: (c.author && c.author.login) ? String(c.author.login) : 'unknown',
          body: includeBodies ? (c.body || '') : undefined
        }))
      });
    }
    const pInfo = rt && rt.pageInfo ? rt.pageInfo : { hasNextPage: false, endCursor: null };
    if (!pInfo.hasNextPage) {
      return { viewer, prMeta, threads };
    }
    cursor = pInfo.endCursor;
  }
  fail('PR_PAGINATION_INCOMPLETE', `Review thread pagination reached --max-pages (${maxPages})`, EXIT_BLOCKED);
}

function assertOpenAndFreshHead(header, expectedHead) {
  if (header.state !== 'OPEN') {
    fail('PR_NOT_OPEN', `Pull request state is ${header.state}; expected OPEN`, EXIT_BLOCKED, { state: header.state });
  }
  if (header.headSha !== expectedHead) {
    fail('PR_STALE_HEAD', `Remote PR HEAD (${header.headSha}) does not match expected (${expectedHead})`, EXIT_BLOCKED, {
      remote_head: header.headSha,
      expected_head: expectedHead
    });
  }
}

function buildMarker(key) {
  return key ? `<!-- b3-pr-key:${key} -->` : '';
}

function appendMarkerIfNeeded(body, key) {
  if (!key) return body;
  const marker = buildMarker(key);
  if (body.includes(marker)) return body;
  return `${body.trimEnd()}\n\n${marker}`;
}

function handleFetch(flags) {
  const repo = validateRepo(flags.repo);
  const prNumber = validatePr(flags.pr);
  const maxPages = validateMaxPages(flags['max-pages']);
  const includeResolved = Boolean(flags['include-resolved']);
  const includeBodies = Boolean(flags['include-bodies']);

  const { viewer, prMeta, threads } = fetchAllReviewThreads(repo.owner, repo.name, prNumber, maxPages, includeBodies);
  const rawIssueComments = fetchRestPaginated(`repos/${repo.full}/issues/${prNumber}/comments`, maxPages);

  const visibleThreads = includeResolved ? threads : threads.filter((t) => !t.isResolved);

  const formattedThreads = visibleThreads.map((t) => {
    const authors = [...new Set(t.comments.map((c) => c.author))].map((a) => frameUntrustedText(a));
    const obj = {
      id: t.id,
      target_kind: 'review_thread',
      is_resolved: t.isResolved,
      is_outdated: t.isOutdated,
      path: frameUntrustedText(t.path),
      line: t.line,
      comment_count: t.comments.length,
      authors
    };
    if (includeBodies) {
      obj.comments = t.comments.map((c) => ({
        id: c.id,
        author: frameUntrustedText(c.author),
        body: frameUntrustedText(c.body)
      }));
    }
    return obj;
  });

  const formattedGeneral = rawIssueComments.map((c) => {
    const obj = {
      id: String(c.id),
      target_kind: 'general_comment',
      resolvable: false,
      author: frameUntrustedText((c.user && c.user.login) ? c.user.login : 'unknown')
    };
    if (includeBodies) {
      obj.body = frameUntrustedText(c.body || '');
    }
    return obj;
  });

  const prOut = {
    number: prMeta.number,
    state: prMeta.state,
    head_sha: prMeta.headSha,
    title: frameUntrustedText(prMeta.title),
    base_ref: frameUntrustedText(prMeta.baseRefName),
    head_ref: frameUntrustedText(prMeta.headRefName)
  };
  if (includeBodies) {
    prOut.body = frameUntrustedText(prMeta.body);
  }

  emit({
    status: 'PR_FETCH_OK',
    repo: repo.full,
    pr: prNumber,
    viewer,
    untrusted_data_framed: true,
    include_resolved: includeResolved,
    include_bodies: includeBodies,
    pull_request: prOut,
    counts: {
      total_review_threads: threads.length,
      returned_review_threads: formattedThreads.length,
      general_comments: formattedGeneral.length
    },
    review_threads: formattedThreads,
    general_comments: formattedGeneral
  }, EXIT_OK);
}

function handleReply(flags) {
  const repo = validateRepo(flags.repo);
  const prNumber = validatePr(flags.pr);
  const expectedHead = validateSha(flags['expected-head'], '--expected-head');
  const targetKind = flags['target-kind'];
  if (!ALLOWED_TARGET_KINDS.has(targetKind)) {
    fail('PR_INVALID_ARGS', 'Invalid --target-kind (expected review_thread|general_comment)', EXIT_ERROR);
  }
  const targetId = validateId(flags['target-id'], '--target-id');
  const rawBody = readSafeInputFile(flags['body-file'], '--body-file');
  if (!rawBody.trim()) {
    fail('PR_INVALID_ARGS', '--body-file is empty', EXIT_ERROR);
  }
  const key = validateKey(flags['idempotency-key']);
  const finalBody = appendMarkerIfNeeded(rawBody, key);
  if (finalBody.length > MAX_BODY_CHARS) {
    fail('PR_FILE_GUARD', `Reply body exceeds ${MAX_BODY_CHARS} chars`, EXIT_ERROR);
  }
  const maxPages = validateMaxPages(flags['max-pages']);
  const stateFile = validateStateFilePath(flags['state-file']);
  const isDraft = Boolean(flags.draft);
  const authWrite = Boolean(flags['authorize-write']);

  if (isDraft && authWrite) {
    fail('PR_INVALID_ARGS', '--draft cannot be combined with --authorize-write', EXIT_ERROR);
  }
  if (isDraft) {
    emit({
      status: 'PR_DRAFT_OK',
      action: 'reply',
      mutated: false,
      repo: repo.full,
      pr: prNumber,
      expected_head: expectedHead,
      target_kind: targetKind,
      target_id: targetId,
      idempotency_key: key || null,
      body_preview: finalBody
    }, EXIT_OK);
  }
  if (!authWrite) {
    fail('PR_AUTH_REQUIRED', 'Explicit --authorize-write is required to post a PR reply (or use --draft)', EXIT_BLOCKED);
  }

  const header = fetchPrHeader(repo.owner, repo.name, prNumber);
  assertOpenAndFreshHead(header, expectedHead);
  const marker = buildMarker(key);

  if (targetKind === 'review_thread') {
    const { threads } = fetchAllReviewThreads(repo.owner, repo.name, prNumber, maxPages, true);
    const thread = threads.find((t) => t.id === targetId);
    if (!thread) {
      fail('PR_TARGET_MISMATCH', `Review thread ${targetId} does not belong to ${repo.full}#${prNumber}`, EXIT_ERROR);
    }
    if (marker) {
      const existing = thread.comments.find(
        (c) => c.author.toLowerCase() === header.viewer.toLowerCase() && (c.body || '').includes(marker)
      );
      if (existing) {
        recordAuditState(stateFile, { action: 'reply', status: 'PR_IDEMPOTENT_SKIP', repo: repo.full, pr: prNumber, target_kind: targetKind, target_id: targetId, key, comment_id: existing.id });
        emit({ status: 'PR_IDEMPOTENT_SKIP', action: 'reply', mutated: false, target_kind: targetKind, target_id: targetId, existing_comment_id: existing.id }, EXIT_OK);
      }
    }
    const mut = `
      mutation($threadId: ID!, $body: String!) {
        addPullRequestReviewThreadReply(input: { pullRequestReviewThreadId: $threadId, body: $body }) {
          comment { id url }
        }
      }
    `;
    const res = ghGraphQL(mut, { threadId: targetId, body: finalBody });
    const created = res.addPullRequestReviewThreadReply && res.addPullRequestReviewThreadReply.comment;
    if (!created || !created.id) {
      fail('PR_API_ERROR', 'Thread reply did not return a created comment ID', EXIT_ERROR);
    }
    // Post-write remote verification
    const postHeader = fetchPrHeader(repo.owner, repo.name, prNumber);
    if (postHeader.headSha !== expectedHead) {
      fail('PR_POST_WRITE_HEAD_MOVED', `PR HEAD moved concurrently after reply (${expectedHead} -> ${postHeader.headSha})`, EXIT_BLOCKED, {
        comment_id: String(created.id),
        remote_head: postHeader.headSha
      });
    }
    recordAuditState(stateFile, { action: 'reply', status: 'PR_REPLY_OK', repo: repo.full, pr: prNumber, target_kind: targetKind, target_id: targetId, key: key || null, comment_id: String(created.id), head_sha: postHeader.headSha });
    emit({
      status: 'PR_REPLY_OK',
      action: 'reply',
      mutated: true,
      repo: repo.full,
      pr: prNumber,
      target_kind: targetKind,
      target_id: targetId,
      comment_id: String(created.id),
      verified_head: postHeader.headSha
    }, EXIT_OK);
  } else {
    const comments = fetchRestPaginated(`repos/${repo.full}/issues/${prNumber}/comments`, maxPages);
    const target = comments.find((c) => String(c.id) === targetId);
    if (!target) {
      fail('PR_TARGET_MISMATCH', `General PR comment ${targetId} does not belong to ${repo.full}#${prNumber}`, EXIT_ERROR);
    }
    if (marker) {
      const existing = comments.find(
        (c) => c.user && String(c.user.login || '').toLowerCase() === header.viewer.toLowerCase() && String(c.body || '').includes(marker)
      );
      if (existing) {
        recordAuditState(stateFile, { action: 'reply', status: 'PR_IDEMPOTENT_SKIP', repo: repo.full, pr: prNumber, target_kind: targetKind, target_id: targetId, key, comment_id: String(existing.id) });
        emit({ status: 'PR_IDEMPOTENT_SKIP', action: 'reply', mutated: false, target_kind: targetKind, target_id: targetId, existing_comment_id: String(existing.id) }, EXIT_OK);
      }
    }
    const created = ghRestPost(`repos/${repo.full}/issues/${prNumber}/comments`, { body: finalBody });
    if (!created || !created.id) {
      fail('PR_API_ERROR', 'General PR comment reply did not return a created comment ID', EXIT_ERROR);
    }
    const postHeader = fetchPrHeader(repo.owner, repo.name, prNumber);
    if (postHeader.headSha !== expectedHead) {
      fail('PR_POST_WRITE_HEAD_MOVED', `PR HEAD moved concurrently after reply (${expectedHead} -> ${postHeader.headSha})`, EXIT_BLOCKED, {
        comment_id: String(created.id),
        remote_head: postHeader.headSha
      });
    }
    recordAuditState(stateFile, { action: 'reply', status: 'PR_REPLY_OK', repo: repo.full, pr: prNumber, target_kind: targetKind, target_id: targetId, key: key || null, comment_id: String(created.id), head_sha: postHeader.headSha });
    emit({
      status: 'PR_REPLY_OK',
      action: 'reply',
      mutated: true,
      repo: repo.full,
      pr: prNumber,
      target_kind: targetKind,
      target_id: targetId,
      comment_id: String(created.id),
      verified_head: postHeader.headSha
    }, EXIT_OK);
  }
}

function handleResolve(flags) {
  const repo = validateRepo(flags.repo);
  const prNumber = validatePr(flags.pr);
  const expectedHead = validateSha(flags['expected-head'], '--expected-head');
  const threadId = validateId(flags['thread-id'], '--thread-id');
  const fixCommit = validateSha(flags['fix-commit'], '--fix-commit');
  const verifyStatus = flags['verify-status'];
  if (!ALLOWED_VERIFY_STATUS.has(verifyStatus)) {
    fail('PR_INVALID_ARGS', 'Invalid --verify-status (expected PASS|FAIL|INCOMPLETE)', EXIT_ERROR);
  }
  const maxPages = validateMaxPages(flags['max-pages']);
  const stateFile = validateStateFilePath(flags['state-file']);
  const isDraft = Boolean(flags.draft);
  const authResolve = Boolean(flags['authorize-resolve']);

  if (isDraft && authResolve) {
    fail('PR_INVALID_ARGS', '--draft cannot be combined with --authorize-resolve', EXIT_ERROR);
  }
  if (/^[0-9]+$/.test(threadId) || threadId.startsWith('IC_')) {
    fail('PR_NOT_RESOLVABLE', `General PR comments (${threadId}) cannot be resolved as review threads`, EXIT_ERROR);
  }
  if (verifyStatus !== 'PASS') {
    fail('PR_VERIFY_REQUIRED', `Thread resolution blocked: verification status is ${verifyStatus} (PASS required)`, EXIT_BLOCKED);
  }
  if (isDraft) {
    emit({
      status: 'PR_DRAFT_OK',
      action: 'resolve',
      mutated: false,
      repo: repo.full,
      pr: prNumber,
      expected_head: expectedHead,
      thread_id: threadId,
      fix_commit: fixCommit,
      verify_status: verifyStatus
    }, EXIT_OK);
  }
  if (!authResolve) {
    fail('PR_AUTH_REQUIRED', 'Explicit --authorize-resolve is required to resolve a review thread (or use --draft)', EXIT_BLOCKED);
  }

  const { prMeta, threads } = fetchAllReviewThreads(repo.owner, repo.name, prNumber, maxPages, false);
  assertOpenAndFreshHead({ state: prMeta.state, headSha: prMeta.headSha }, expectedHead);

  const thread = threads.find((t) => t.id === threadId);
  if (!thread) {
    const general = fetchRestPaginated(`repos/${repo.full}/issues/${prNumber}/comments`, maxPages);
    if (general.some((c) => String(c.id) === threadId || String(c.node_id || '') === threadId)) {
      fail('PR_NOT_RESOLVABLE', `Target ${threadId} is a general PR comment and cannot be resolved`, EXIT_ERROR);
    }
    fail('PR_TARGET_MISMATCH', `Review thread ${threadId} does not belong to ${repo.full}#${prNumber}`, EXIT_ERROR);
  }

  // Prove fix_commit is an ancestor of remote PR HEAD
  const cmp = ghRestGet(`repos/${repo.full}/compare/${fixCommit}...${prMeta.headSha}`, { allowNotFound: true });
  if (cmp.notFound || !cmp.data || typeof cmp.data !== 'object') {
    fail('PR_FIX_NOT_REMOTE', `Fix commit ${fixCommit} was not found on remote ${repo.full}`, EXIT_BLOCKED);
  }
  const cmpStatus = String(cmp.data.status || '');
  const behindBy = Number(cmp.data.behind_by ?? -1);
  if (!(cmpStatus === 'identical' || (cmpStatus === 'ahead' && behindBy === 0))) {
    fail('PR_FIX_NOT_REMOTE', `Fix commit ${fixCommit} is not reachable in remote PR HEAD ${prMeta.headSha} (compare status=${cmpStatus}, behind_by=${behindBy})`, EXIT_BLOCKED);
  }

  if (thread.isResolved) {
    recordAuditState(stateFile, { action: 'resolve', status: 'PR_ALREADY_RESOLVED', repo: repo.full, pr: prNumber, thread_id: threadId, fix_commit: fixCommit });
    emit({ status: 'PR_ALREADY_RESOLVED', action: 'resolve', mutated: false, thread_id: threadId, verified_head: prMeta.headSha }, EXIT_OK);
  }

  const mut = `
    mutation($threadId: ID!) {
      resolveReviewThread(input: { threadId: $threadId }) {
        thread { id isResolved }
      }
    }
  `;
  const res = ghGraphQL(mut, { threadId });
  const mutatedThread = res.resolveReviewThread && res.resolveReviewThread.thread;
  if (!mutatedThread || !mutatedThread.isResolved) {
    fail('PR_API_ERROR', 'resolveReviewThread did not confirm isResolved=true', EXIT_ERROR);
  }

  // Post-write remote verification of both thread state and PR HEAD
  const verifyQuery = `
    query($owner: String!, $repo: String!, $pr: Int!, $threadId: ID!) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $pr) { headRefOid }
      }
      node(id: $threadId) {
        ... on PullRequestReviewThread { id isResolved }
      }
    }
  `;
  const vData = ghGraphQL(verifyQuery, { owner: repo.owner, repo: repo.name, pr: prNumber, threadId });
  const postHead = String(vData.repository?.pullRequest?.headRefOid || '').toLowerCase();
  const postResolved = Boolean(vData.node && vData.node.isResolved);
  if (!postResolved) {
    fail('PR_API_ERROR', `Post-write verification failed: thread ${threadId} is not resolved remotely`, EXIT_ERROR);
  }
  if (postHead !== expectedHead) {
    fail('PR_POST_WRITE_HEAD_MOVED', `PR HEAD moved concurrently after resolve (${expectedHead} -> ${postHead})`, EXIT_BLOCKED, {
      thread_id: threadId,
      remote_head: postHead
    });
  }

  recordAuditState(stateFile, { action: 'resolve', status: 'PR_RESOLVE_OK', repo: repo.full, pr: prNumber, thread_id: threadId, fix_commit: fixCommit, head_sha: postHead });
  emit({
    status: 'PR_RESOLVE_OK',
    action: 'resolve',
    mutated: true,
    repo: repo.full,
    pr: prNumber,
    thread_id: threadId,
    fix_commit: fixCommit,
    is_resolved: true,
    verified_head: postHead
  }, EXIT_OK);
}

function parseAndValidateInlineJson(inlineJsonPath) {
  const raw = readSafeInputFile(inlineJsonPath, '--inline-json');
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    fail('PR_INVALID_ARGS', '--inline-json is not valid JSON', EXIT_ERROR);
  }
  if (!Array.isArray(parsed) || parsed.length === 0) {
    fail('PR_INVALID_ARGS', '--inline-json must be a non-empty JSON array', EXIT_ERROR);
  }
  return parsed.map((item, idx) => {
    if (!item || typeof item !== 'object') {
      fail('PR_INVALID_ARGS', `Inline finding[${idx}] must be an object`, EXIT_ERROR);
    }
    if (item.status !== 'CONFIRMED') {
      fail('PR_INVALID_ARGS', `Inline finding[${idx}] rejected: status must be CONFIRMED (got ${String(item.status)})`, EXIT_ERROR);
    }
    if (!ALLOWED_SEVERITIES.has(item.severity)) {
      fail('PR_INVALID_ARGS', `Inline finding[${idx}] rejected: invalid severity ${String(item.severity)}`, EXIT_ERROR);
    }
    const p = String(item.path || '');
    if (!p || hasControlChars(p) || p.startsWith('/') || p.includes('\\') || p.split('/').includes('..')) {
      fail('PR_INVALID_ARGS', `Inline finding[${idx}] has invalid path`, EXIT_ERROR);
    }
    const line = item.line;
    if (!Number.isInteger(line) || line < 1) {
      fail('PR_INVALID_ARGS', `Inline finding[${idx}] must have positive integer line`, EXIT_ERROR);
    }
    const side = item.side ? String(item.side) : 'RIGHT';
    if (!ALLOWED_SIDES.has(side)) {
      fail('PR_INVALID_ARGS', `Inline finding[${idx}] has invalid side (expected RIGHT|LEFT)`, EXIT_ERROR);
    }
    const title = String(item.title || '').trim();
    const body = String(item.body || '').trim();
    const suggestedFix = String(item.suggested_fix || '').trim();
    if (!title || !body || !suggestedFix) {
      fail('PR_INVALID_ARGS', `Inline finding[${idx}] requires non-empty title, body, and suggested_fix`, EXIT_ERROR);
    }
    const formattedBody = `**[${item.severity}] — ${title}**\n\n${body}\n\n**Suggested fix:** ${suggestedFix}`;
    if (formattedBody.length > MAX_BODY_CHARS) {
      fail('PR_FILE_GUARD', `Inline finding[${idx}] exceeds ${MAX_BODY_CHARS} chars`, EXIT_ERROR);
    }
    return { path: p, line, side, body: formattedBody };
  });
}

function handleComment(flags) {
  const repo = validateRepo(flags.repo);
  const prNumber = validatePr(flags.pr);
  const expectedHead = validateSha(flags['expected-head'], '--expected-head');
  const mode = flags.mode;
  if (!ALLOWED_MODES.has(mode)) {
    fail('PR_INVALID_ARGS', 'Invalid --mode (expected summary|inline|both)', EXIT_ERROR);
  }
  const event = flags.event || 'COMMENT';
  if (!ALLOWED_EVENTS.has(event)) {
    fail('PR_INVALID_ARGS', 'Invalid --event (expected COMMENT|APPROVE|REQUEST_CHANGES)', EXIT_ERROR);
  }
  const authReviewEvent = flags['authorize-review-event'];
  if (authReviewEvent !== undefined && !['APPROVE', 'REQUEST_CHANGES'].includes(authReviewEvent)) {
    fail('PR_INVALID_ARGS', 'Invalid --authorize-review-event (expected APPROVE|REQUEST_CHANGES)', EXIT_ERROR);
  }
  if (authReviewEvent !== undefined && event === 'COMMENT') {
    fail('PR_INVALID_ARGS', '--authorize-review-event cannot be set when --event is COMMENT', EXIT_ERROR);
  }
  const key = validateKey(flags['idempotency-key']);
  const maxPages = validateMaxPages(flags['max-pages']);
  const stateFile = validateStateFilePath(flags['state-file']);
  const isDraft = Boolean(flags.draft);
  const authWrite = Boolean(flags['authorize-write']);

  if (isDraft && (authWrite || authReviewEvent !== undefined)) {
    fail('PR_INVALID_ARGS', '--draft cannot be combined with --authorize-write or --authorize-review-event', EXIT_ERROR);
  }

  let summaryBody = '';
  let inlineComments = [];

  if (mode === 'summary' || mode === 'both') {
    if (!flags['summary-file']) {
      fail('PR_INVALID_ARGS', `--summary-file is required for --mode ${mode}`, EXIT_ERROR);
    }
    summaryBody = readSafeInputFile(flags['summary-file'], '--summary-file');
    if (!summaryBody.trim()) {
      fail('PR_INVALID_ARGS', '--summary-file is empty', EXIT_ERROR);
    }
  } else if (flags['summary-file']) {
    fail('PR_INVALID_ARGS', '--summary-file is not allowed with --mode inline', EXIT_ERROR);
  }

  if (mode === 'inline' || mode === 'both') {
    if (!flags['inline-json']) {
      fail('PR_INVALID_ARGS', `--inline-json is required for --mode ${mode}`, EXIT_ERROR);
    }
    inlineComments = parseAndValidateInlineJson(flags['inline-json']);
  } else if (flags['inline-json']) {
    fail('PR_INVALID_ARGS', '--inline-json is not allowed with --mode summary', EXIT_ERROR);
  }

  const finalBody = key ? (summaryBody ? appendMarkerIfNeeded(summaryBody, key) : buildMarker(key)) : summaryBody;
  if (finalBody.length > MAX_BODY_CHARS) {
    fail('PR_FILE_GUARD', `Summary body exceeds ${MAX_BODY_CHARS} chars`, EXIT_ERROR);
  }

  if (isDraft) {
    emit({
      status: 'PR_DRAFT_OK',
      action: 'comment',
      mutated: false,
      repo: repo.full,
      pr: prNumber,
      expected_head: expectedHead,
      mode,
      event,
      idempotency_key: key || null,
      summary_preview: finalBody || null,
      inline_count: inlineComments.length,
      inline_preview: inlineComments
    }, EXIT_OK);
  }

  if (!authWrite) {
    fail('PR_AUTH_REQUIRED', 'Explicit --authorize-write is required to publish PR comments (or use --draft)', EXIT_BLOCKED);
  }
  if (event !== 'COMMENT' && authReviewEvent !== event) {
    fail('PR_EVENT_UNAUTHORIZED', `Review event ${event} requires matching --authorize-review-event ${event}`, EXIT_BLOCKED);
  }

  const header = fetchPrHeader(repo.owner, repo.name, prNumber);
  assertOpenAndFreshHead(header, expectedHead);

  if (inlineComments.length > 0) {
    const prFiles = fetchRestPaginated(`repos/${repo.full}/pulls/${prNumber}/files`, maxPages);
    const validPaths = new Set(prFiles.map((f) => String(f.filename || '')));
    for (const ic of inlineComments) {
      if (!validPaths.has(ic.path)) {
        fail('PR_TARGET_MISMATCH', `Inline path ${ic.path} is not in PR ${repo.full}#${prNumber} changed files`, EXIT_ERROR);
      }
    }
  }

  const marker = buildMarker(key);
  if (marker) {
    const issueComments = fetchRestPaginated(`repos/${repo.full}/issues/${prNumber}/comments`, maxPages);
    const dupComment = issueComments.find(
      (c) => c.user && String(c.user.login || '').toLowerCase() === header.viewer.toLowerCase() && String(c.body || '').includes(marker)
    );
    if (dupComment) {
      recordAuditState(stateFile, { action: 'comment', status: 'PR_IDEMPOTENT_SKIP', repo: repo.full, pr: prNumber, mode, key, existing_id: String(dupComment.id) });
      emit({ status: 'PR_IDEMPOTENT_SKIP', action: 'comment', mutated: false, mode, existing_id: String(dupComment.id) }, EXIT_OK);
    }
    const reviews = fetchRestPaginated(`repos/${repo.full}/pulls/${prNumber}/reviews`, maxPages);
    const dupReview = reviews.find(
      (r) => r.user && String(r.user.login || '').toLowerCase() === header.viewer.toLowerCase() && String(r.body || '').includes(marker)
    );
    if (dupReview) {
      recordAuditState(stateFile, { action: 'comment', status: 'PR_IDEMPOTENT_SKIP', repo: repo.full, pr: prNumber, mode, key, existing_id: String(dupReview.id) });
      emit({ status: 'PR_IDEMPOTENT_SKIP', action: 'comment', mutated: false, mode, existing_id: String(dupReview.id) }, EXIT_OK);
    }
  }

  let created;
  let transport;
  if (mode === 'summary' && event === 'COMMENT') {
    transport = 'issue_comment';
    created = ghRestPost(`repos/${repo.full}/issues/${prNumber}/comments`, { body: finalBody });
  } else {
    transport = 'pull_review';
    const reviewPayload = {
      commit_id: expectedHead,
      event,
      body: finalBody
    };
    if (inlineComments.length > 0) {
      reviewPayload.comments = inlineComments;
    }
    created = ghRestPost(`repos/${repo.full}/pulls/${prNumber}/reviews`, reviewPayload);
  }

  if (!created || !created.id) {
    fail('PR_API_ERROR', `Publishing PR comment (${transport}) did not return a created ID`, EXIT_ERROR);
  }

  const postHeader = fetchPrHeader(repo.owner, repo.name, prNumber);
  if (postHeader.headSha !== expectedHead) {
    fail('PR_POST_WRITE_HEAD_MOVED', `PR HEAD moved concurrently after publishing comment (${expectedHead} -> ${postHeader.headSha})`, EXIT_BLOCKED, {
      created_id: String(created.id),
      remote_head: postHeader.headSha
    });
  }

  recordAuditState(stateFile, { action: 'comment', status: 'PR_COMMENT_OK', repo: repo.full, pr: prNumber, mode, event, transport, key: key || null, created_id: String(created.id), head_sha: postHeader.headSha });
  emit({
    status: 'PR_COMMENT_OK',
    action: 'comment',
    mutated: true,
    repo: repo.full,
    pr: prNumber,
    mode,
    event,
    transport,
    created_id: String(created.id),
    inline_count: inlineComments.length,
    verified_head: postHeader.headSha
  }, EXIT_OK);
}

const { cmd, flags } = parseArgs(process.argv.slice(2));
switch (cmd) {
  case 'fetch':
    handleFetch(flags);
    break;
  case 'reply':
    handleReply(flags);
    break;
  case 'resolve':
    handleResolve(flags);
    break;
  case 'comment':
    handleComment(flags);
    break;
  default:
    fail('PR_INVALID_ARGS', `Unknown subcommand: ${cmd} (expected: fetch, reply, resolve, comment)`, EXIT_ERROR);
}
