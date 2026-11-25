#!/usr/bin/env node
import crypto from 'node:crypto';
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
const LOCK_STALE_MS = 120000;

const UNTRUSTED_START = 'BEGIN_UNTRUSTED_PR_DATA';
const UNTRUSTED_END = 'END_UNTRUSTED_PR_DATA';

const REPO_RE = /^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/;
const PR_RE = /^[1-9][0-9]*$/;
const SHA_RE = /^[0-9a-fA-F]{40}$/;
const ID_RE = /^[A-Za-z0-9_=-]{1,128}$/;
const KEY_RE = /^[A-Za-z0-9._:-]{4,80}$/;
const SAFE_GH_ARG_RE = /^[A-Za-z0-9_./:?=&-]+$/;
const MARKER_SCAN_RE = /<!--\s*b3-pr-key:([A-Za-z0-9._:-]{4,80})(?:;op=([0-9a-f]{16}))?\s*-->/g;
const WIN_DEVICE_RE = /^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$/i;

const ALLOWED_SEVERITIES = new Set(['CRITICAL', 'HIGH', 'MEDIUM', 'LOW']);
const ALLOWED_SIDES = new Set(['RIGHT', 'LEFT']);
const ALLOWED_EVENTS = new Set(['COMMENT', 'APPROVE', 'REQUEST_CHANGES']);
const ALLOWED_MODES = new Set(['summary', 'inline', 'both']);
const ALLOWED_TARGET_KINDS = new Set(['review_thread', 'general_comment']);
const ALLOWED_BASES = new Set(['CONFIRMED_FIXED', 'ALREADY_FIXED', 'DUPLICATE_FIXED']);

// Structured fail-closed exit (R002: guarantees full stdout flush on pipes/redirects).
class B3Exit extends Error {
  constructor(payload, code) {
    super(payload.status || 'EXIT');
    this.payload = payload;
    this.code = code;
  }
}

function emit(payload, code) {
  throw new B3Exit(payload, code);
}

function fail(status, message, code = EXIT_ERROR, extra = {}) {
  emit({ status, error: message, ...extra }, code);
}

function hasControlChars(str) {
  return /[\x00-\x1F\x7F]/.test(str);
}

function sha256Hex(str) {
  return crypto.createHash('sha256').update(str, 'utf8').digest('hex');
}

function normalizeText(str) {
  return String(str || '').replace(/\r\n/g, '\n').trim();
}

function stripMarkers(str) {
  return normalizeText(String(str || '').replace(MARKER_SCAN_RE, ''));
}

function sanitizeUntrustedText(val) {
  let s = val === null || val === undefined ? '' : String(val);
  s = s.replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g, '');
  s = s.replace(/[\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]/g, '');
  s = s.replace(/[\u{E0000}-\u{E007F}]/gu, '');
  s = s.replace(/BEGIN_UNTRUSTED_PR_DATA/gi, 'BEGIN-UNTRUSTED-PR-DATA-ESCAPED');
  s = s.replace(/END_UNTRUSTED_PR_DATA/gi, 'END-UNTRUSTED-PR-DATA-ESCAPED');
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
    'evidence-file',
    'mode',
    'event',
    'summary-file',
    'inline-json',
    'authorize-review-event'
  ]);
  const allowedByCmd = {
    fetch: new Set(['repo', 'pr', 'include-resolved', 'include-bodies', 'thread-id', 'max-pages', 'state-file']),
    reply: new Set(['repo', 'pr', 'expected-head', 'target-kind', 'target-id', 'body-file', 'idempotency-key', 'authorize-write', 'draft', 'state-file', 'max-pages']),
    resolve: new Set(['repo', 'pr', 'expected-head', 'thread-id', 'fix-commit', 'evidence-file', 'authorize-resolve', 'draft', 'state-file', 'max-pages']),
    comment: new Set(['repo', 'pr', 'expected-head', 'mode', 'event', 'summary-file', 'inline-json', 'idempotency-key', 'authorize-write', 'authorize-review-event', 'draft', 'state-file', 'max-pages'])
  };
  const cmdAllowed = allowedByCmd[cmd];
  if (!cmdAllowed) {
    fail('PR_INVALID_ARGS', `Unknown subcommand: ${cmd} (expected: fetch, reply, resolve, comment)`, EXIT_ERROR);
  }
  for (let i = 1; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith('--')) {
      fail('PR_INVALID_ARGS', `Unexpected positional argument: ${arg}`, EXIT_ERROR);
    }
    const name = arg.slice(2);
    if (!name || !cmdAllowed.has(name)) {
      fail('PR_INVALID_ARGS', `Flag --${name} is not allowed for subcommand ${cmd}`, EXIT_ERROR);
    }
    if (booleanFlags.has(name)) {
      flags[name] = true;
    } else if (valueFlags.has(name)) {
      if (i + 1 >= argv.length || argv[i + 1].startsWith('--')) {
        fail('PR_INVALID_ARGS', `Missing value for --${name}`, EXIT_ERROR);
      }
      flags[name] = argv[i + 1];
      i += 1;
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

function validateThreadIdList(raw) {
  if (!raw) return [];
  const parts = String(raw).split(',').map((s) => s.trim()).filter(Boolean);
  if (parts.length === 0 || parts.length > 50) {
    fail('PR_INVALID_ARGS', 'Invalid --thread-id list (expected 1-50 comma-separated IDs)', EXIT_ERROR);
  }
  return parts.map((id) => validateId(id, '--thread-id'));
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

function validateRelPath(p, label) {
  if (!p || hasControlChars(p) || p.startsWith('/') || p.includes('\\') || p.split('/').includes('..')) {
    fail('PR_INVALID_ARGS', `Invalid relative path in ${label}`, EXIT_ERROR);
  }
  return p;
}

// --- R007: Unified safe-path & symlink/reparse-point guard ---
function validateRawPathSyntax(filePath, flagName, rejectTraversal = true) {
  if (!filePath || hasControlChars(filePath) || filePath.includes('\0')) {
    fail('PR_INVALID_ARGS', `Invalid ${flagName}`, EXIT_ERROR);
  }
  if (/^[\\/]{2}/.test(filePath)) {
    fail('PR_FILE_GUARD', `UNC/device namespace path rejected for ${flagName}`, EXIT_ERROR);
  }
  if (/^[A-Za-z]:(?![\\/])/.test(filePath)) {
    fail('PR_FILE_GUARD', `Drive-relative path rejected for ${flagName}`, EXIT_ERROR);
  }
  // Reject Windows Alternate Data Streams (colon outside leading drive letter).
  const withoutDrive = filePath.replace(/^[A-Za-z]:/, '');
  if (withoutDrive.includes(':')) {
    fail('PR_FILE_GUARD', `Unsafe path syntax rejected for ${flagName}`, EXIT_ERROR);
  }
  const segments = withoutDrive.split(/[\\/]+/).filter(Boolean);
  if (rejectTraversal && segments.includes('..')) {
    fail('PR_FILE_GUARD', `Path traversal rejected for ${flagName}`, EXIT_ERROR);
  }
  for (const seg of segments) {
    const cleaned = seg.replace(/[\s.]+$/g, '').trim();
    const baseStem = seg.split('.')[0].trim();
    if (WIN_DEVICE_RE.test(cleaned) || WIN_DEVICE_RE.test(baseStem)) {
      fail('PR_FILE_GUARD', `Reserved device path rejected for ${flagName}`, EXIT_ERROR);
    }
  }
}

function validateSafeFilePath(filePath, flagName, options = {}) {
  const { mustExist = true, rejectTraversal = true, maxBytes = MAX_FILE_BYTES } = options;
  validateRawPathSyntax(filePath, flagName, rejectTraversal);

  const resolved = path.resolve(filePath);
  let leafStat = null;
  try {
    leafStat = fs.lstatSync(resolved);
  } catch (err) {
    if (mustExist || !err || err.code !== 'ENOENT') {
      fail('PR_FILE_GUARD', `Cannot access ${flagName}: ${err?.code || 'ERR'}`, EXIT_ERROR);
    }
  }
  if (leafStat) {
    if (leafStat.isSymbolicLink()) {
      fail('PR_FILE_GUARD', `Symlink/reparse point rejected for ${flagName}`, EXIT_ERROR);
    }
    if (!leafStat.isFile()) {
      fail('PR_FILE_GUARD', `Regular file required for ${flagName}`, EXIT_ERROR);
    }
    if (mustExist && leafStat.size > maxBytes) {
      fail('PR_FILE_GUARD', `${flagName} exceeds ${maxBytes} bytes`, EXIT_ERROR);
    }
  }

  // Walk every existing ancestor directory (only skipping macOS OS-mandated /var,/tmp,/etc symlinks).
  let cur = path.dirname(resolved);
  const visited = new Set();
  while (cur && !visited.has(cur)) {
    visited.add(cur);
    if (process.platform === 'darwin' && (cur === '/var' || cur === '/tmp' || cur === '/etc')) {
      break;
    }
    let pst = null;
    try {
      pst = fs.lstatSync(cur);
    } catch (err) {
      if (!err || err.code !== 'ENOENT') {
        fail('PR_FILE_GUARD', `Cannot inspect ancestor for ${flagName}: ${err?.code || 'ERR'}`, EXIT_ERROR);
      }
    }
    if (pst) {
      if (pst.isSymbolicLink()) {
        fail('PR_FILE_GUARD', `Symlink/reparse ancestor directory rejected for ${flagName}`, EXIT_ERROR);
      }
      if (!pst.isDirectory()) {
        fail('PR_FILE_GUARD', `Non-directory ancestor rejected for ${flagName}`, EXIT_ERROR);
      }
    }
    const next = path.dirname(cur);
    if (next === cur) break;
    cur = next;
  }
  return resolved;
}

function readSafeInputFile(filePath, flagName, maxBytes = MAX_FILE_BYTES) {
  const resolved = validateSafeFilePath(filePath, flagName, { mustExist: true, rejectTraversal: true, maxBytes });
  return fs.readFileSync(resolved, 'utf8').replace(/^\uFEFF/, '');
}

// --- R003 / R004: State-file locking, audit log & reconciliation guard ---
function readStateRecords(statePath) {
  if (!statePath || !fs.existsSync(statePath)) return [];
  let raw;
  try {
    raw = fs.readFileSync(statePath, 'utf8').replace(/^\uFEFF/, '');
  } catch (err) {
    fail('PR_FILE_GUARD', `Cannot read --state-file: ${err?.code || 'ERR'}`, EXIT_ERROR);
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    fail('PR_FILE_GUARD', 'Corrupt JSON in --state-file; refusing to overwrite or bypass reconciliation', EXIT_ERROR);
  }
  if (!Array.isArray(parsed)) {
    fail('PR_FILE_GUARD', '--state-file must contain a JSON array', EXIT_ERROR);
  }
  return parsed;
}

function writeStateRecords(statePath, records) {
  if (!statePath) return;
  const dir = path.dirname(statePath);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
  const tmpPath = `${statePath}.tmp.${process.pid}.${crypto.randomBytes(6).toString('hex')}`;
  fs.writeFileSync(tmpPath, JSON.stringify(records, null, 2) + '\n', { encoding: 'utf8', flag: 'wx', mode: 0o600 });
  fs.renameSync(tmpPath, statePath);
}

function recordAuditState(statePath, entry, options = {}) {
  if (!statePath) return true;
  const { critical = false } = options;
  try {
    const records = readStateRecords(statePath);
    records.push({ ...entry, recorded_at_utc: new Date().toISOString() });
    writeStateRecords(statePath, records);
    return true;
  } catch (err) {
    if (err instanceof B3Exit) {
      if (critical) throw err;
      return false;
    }
    if (critical) {
      fail('PR_FILE_GUARD', `Failed to persist critical state record: ${err?.code || err?.message || 'ERR'}`, EXIT_ERROR);
    }
    return false;
  }
}

function clearReconciliationFlag(statePath, repoFull, prNumber, inspectedHead) {
  if (!statePath) return;
  withStateLock(statePath, () => {
    const records = readStateRecords(statePath);
    if (records.some((r) => r.repo === repoFull && r.pr === prNumber && (r.reconciliation_required || r.status === 'PENDING'))) {
      records.push({
        action: 'reconcile',
        status: 'PR_RECONCILED',
        repo: repoFull,
        pr: prNumber,
        reconciled_head: inspectedHead,
        recorded_at_utc: new Date().toISOString()
      });
      writeStateRecords(statePath, records);
    }
  });
}

function assertNoPendingReconciliation(statePath, repoFull, prNumber) {
  if (!statePath) return;
  const records = readStateRecords(statePath);
  let pending = null;
  for (const r of records) {
    if (r.repo !== repoFull || r.pr !== prNumber) continue;
    if (r.reconciliation_required || r.status === 'PENDING') {
      pending = r;
    } else if (
      r.status === 'PR_RECONCILED' ||
      r.status === 'PR_REPLY_OK' ||
      r.status === 'PR_RESOLVE_OK' ||
      r.status === 'PR_COMMENT_OK' ||
      r.status === 'PR_IDEMPOTENT_SKIP' ||
      r.status === 'PR_ALREADY_RESOLVED'
    ) {
      pending = null;
    }
  }
  if (pending) {
    fail(
      'PR_RECONCILIATION_REQUIRED',
      `Prior unresolved/post-write state (${pending.status}) on ${repoFull}#${prNumber} requires full remote reconciliation via fetch --state-file before continuing`,
      EXIT_BLOCKED,
      { outcome: 'blocked_before_write', mutated: false, pending_record: pending }
    );
  }
}

function withStateLock(statePath, fn) {
  if (!statePath) return fn();
  const dir = path.dirname(statePath);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
  const lockPath = `${statePath}.lock`;
  const lockToken = crypto.randomBytes(16).toString('hex');
  const lockBody = JSON.stringify({ pid: process.pid, token: lockToken, started_at: Date.now() }) + '\n';

  function acquireOnce() {
    const fd = fs.openSync(lockPath, 'wx', 0o600);
    try {
      fs.writeSync(fd, lockBody);
    } finally {
      fs.closeSync(fd);
    }
  }

  try {
    acquireOnce();
  } catch (err) {
    if (err && err.code === 'EEXIST') {
      let st = null;
      try {
        st = fs.lstatSync(lockPath);
      } catch {
        st = null;
      }
      if (st && st.isSymbolicLink()) {
        fail('PR_FILE_GUARD', `Symlink lock file rejected: ${lockPath}`, EXIT_ERROR);
      }
      const isStale = Boolean(st && st.isFile() && Date.now() - st.mtimeMs > LOCK_STALE_MS);
      if (isStale) {
        try {
          const staleCopy = `${lockPath}.stale.${process.pid}.${lockToken.slice(0, 8)}`;
          fs.renameSync(lockPath, staleCopy);
          try { fs.unlinkSync(staleCopy); } catch { /* ignore */ }
          acquireOnce();
        } catch {
          fail('PR_CONCURRENT_LOCK', `Concurrent operation holds lock on ${statePath}; retry after completion`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
        }
      } else {
        fail('PR_CONCURRENT_LOCK', `Concurrent operation holds lock on ${statePath}; retry after completion`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
      }
    } else {
      fail('PR_FILE_GUARD', `Unable to create state lock: ${err?.code || 'ERR'}`, EXIT_ERROR);
    }
  }
  try {
    return fn();
  } finally {
    try {
      const curRaw = fs.readFileSync(lockPath, 'utf8');
      if (curRaw.includes(lockToken)) {
        fs.unlinkSync(lockPath);
      }
    } catch {
      // ignore cleanup error
    }
  }
}

// --- Safe gh CLI transport (stdin-JSON only) ---
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
    if (/[%"!&|<>^\x00-\x1F\x7F]/.test(ghBin)) {
      fail('PR_API_ERROR', 'Unsafe Windows batch path for gh CLI rejected', EXIT_ERROR);
    }
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
  const { data } = invokeGh(['api', endpoint, '--method', 'POST', '--input', '-'], JSON.stringify(bodyObj));
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
  fail('PR_PAGINATION_INCOMPLETE', `Pagination reached --max-pages (${maxPages}) on ${endpointBase}`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
}

// --- Shared PR header & freshness helpers (R004) ---
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

function assertOpenAndFreshHead(header, expectedHead) {
  if (header.state !== 'OPEN') {
    fail('PR_NOT_OPEN', `Pull request state is ${header.state}; expected OPEN`, EXIT_BLOCKED, {
      outcome: 'blocked_before_write',
      mutated: false,
      state: header.state
    });
  }
  if (header.headSha !== expectedHead) {
    fail('PR_STALE_HEAD', `Remote PR HEAD (${header.headSha}) does not match expected (${expectedHead})`, EXIT_BLOCKED, {
      outcome: 'blocked_before_write',
      mutated: false,
      remote_head: header.headSha,
      expected_head: expectedHead
    });
  }
}

function recheckFreshBeforeMutation(owner, repo, prNumber, expectedHead) {
  const liveHeader = fetchPrHeader(owner, repo, prNumber);
  assertOpenAndFreshHead(liveHeader, expectedHead);
  return liveHeader;
}

// --- R008: Targeted single-thread & metadata-first retrieval ---
function paginateNestedThreadComments(threadId, initialConn, maxPages, includeBodies) {
  const commentFields = includeBodies ? 'id author { login } body' : 'id author { login }';
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
  const comments = Array.isArray(initialConn?.nodes) ? [...initialConn.nodes] : [];
  let cInfo = initialConn?.pageInfo || { hasNextPage: false, endCursor: null };
  let nestedPages = 1;
  while (cInfo.hasNextPage) {
    if (nestedPages >= maxPages) {
      fail('PR_PAGINATION_INCOMPLETE', `Nested comment pagination reached --max-pages (${maxPages}) on thread ${threadId}`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
    }
    nestedPages += 1;
    const nData = ghGraphQL(nestedQuery, { threadId, cursor: cInfo.endCursor });
    const nConn = nData.node && nData.node.comments;
    if (!nConn || !Array.isArray(nConn.nodes)) {
      fail('PR_API_ERROR', `Unexpected nested comment response for thread ${threadId}`, EXIT_ERROR);
    }
    comments.push(...nConn.nodes);
    cInfo = nConn.pageInfo || { hasNextPage: false, endCursor: null };
  }
  return comments;
}

function fetchSingleReviewThread(repoFull, prNumber, threadId, maxPages, includeComments) {
  const commentsBlock = includeComments
    ? `comments(first: 100) { totalCount pageInfo { hasNextPage endCursor } nodes { id author { login } body } }`
    : `comments(first: 1) { totalCount }`;
  const query = `
    query($threadId: ID!) {
      node(id: $threadId) {
        ... on PullRequestReviewThread {
          id
          isResolved
          isOutdated
          path
          line
          originalLine
          pullRequest {
            number
            repository { nameWithOwner }
          }
          ${commentsBlock}
        }
      }
    }
  `;
  const data = ghGraphQL(query, { threadId });
  const node = data.node;
  if (!node || !node.id) {
    return null;
  }
  const ownerRepo = String(node.pullRequest?.repository?.nameWithOwner || '').toLowerCase();
  const nodePr = Number(node.pullRequest?.number || 0);
  if (!ownerRepo || ownerRepo !== repoFull.toLowerCase() || nodePr !== prNumber) {
    fail('PR_TARGET_MISMATCH', `Review thread ${threadId} belongs to ${ownerRepo || 'unknown'}#${nodePr}, not ${repoFull}#${prNumber}`, EXIT_ERROR);
  }
  const comments = includeComments ? paginateNestedThreadComments(threadId, node.comments, maxPages, true) : [];
  return {
    id: String(node.id),
    isResolved: Boolean(node.isResolved),
    isOutdated: Boolean(node.isOutdated),
    path: String(node.path || ''),
    line: node.line ?? node.originalLine ?? null,
    totalCount: node.comments?.totalCount ?? comments.length,
    comments: comments.map((c) => ({
      id: String(c.id || ''),
      author: c.author?.login ? String(c.author.login) : 'unknown',
      body: String(c.body || '')
    }))
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

  let cursor = null;
  let viewer = '';
  let prMeta = null;
  const threads = [];

  for (let page = 1; page <= maxPages; page += 1) {
    const data = ghGraphQL(query, { owner, repo, pr: prNumber, cursor });
    if (!viewer && data.viewer?.login) viewer = String(data.viewer.login);
    const pr = data.repository?.pullRequest;
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
    const nodes = Array.isArray(rt?.nodes) ? rt.nodes : [];
    for (const t of nodes) {
      if (!t || !t.id) continue;
      const commentsConn = t.comments || {};
      // R008: paginate nested comments ONLY when includeBodies is requested; metadata-first uses totalCount.
      const comments = includeBodies
        ? paginateNestedThreadComments(String(t.id), commentsConn, maxPages, true)
        : (Array.isArray(commentsConn.nodes) ? commentsConn.nodes : []);
      threads.push({
        id: String(t.id),
        isResolved: Boolean(t.isResolved),
        isOutdated: Boolean(t.isOutdated),
        path: t.path || '',
        line: t.line ?? t.originalLine ?? null,
        totalCount: commentsConn.totalCount ?? comments.length,
        hasMoreNestedComments: Boolean(commentsConn.pageInfo?.hasNextPage) && !includeBodies,
        comments: comments.map((c) => ({
          id: String(c.id || ''),
          author: c.author?.login ? String(c.author.login) : 'unknown',
          body: includeBodies ? String(c.body || '') : undefined
        }))
      });
    }
    const pInfo = rt?.pageInfo || { hasNextPage: false, endCursor: null };
    if (!pInfo.hasNextPage) {
      return { viewer, prMeta, threads };
    }
    cursor = pInfo.endCursor;
  }
  fail('PR_PAGINATION_INCOMPLETE', `Review thread pagination reached --max-pages (${maxPages})`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
}

// --- R003: Operation identity, marker formatting & collision detection ---
function computeOperationIdentity(parts) {
  const canonical = JSON.stringify({
    repo: parts.repo.toLowerCase(),
    pr: parts.pr,
    actor: parts.actor.toLowerCase(),
    op: parts.op,
    target_kind: parts.targetKind || '',
    target_id: parts.targetId || '',
    reviewed_sha: parts.reviewedSha.toLowerCase(),
    mode: parts.mode || '',
    event: parts.event || '',
    payload_sha256: sha256Hex(normalizeText(parts.normalizedPayload))
  });
  const opHash = sha256Hex(canonical).slice(0, 16);
  const key = parts.explicitKey || `auto-${opHash}`;
  const marker = `<!-- b3-pr-key:${key};op=${opHash} -->`;
  return { key, opHash, marker };
}

function appendMarker(body, marker) {
  const cleaned = stripMarkers(body);
  return cleaned ? `${cleaned}\n\n${marker}` : marker;
}

function scanRemoteIdempotency(items, viewerLogin, identity, expectedNormalizedBody, allowLegacyFallback = true) {
  const actorLower = viewerLogin.toLowerCase();
  const expectedStripped = stripMarkers(expectedNormalizedBody);
  for (const item of items) {
    const author = String(item.author || '').toLowerCase();
    if (author !== actorLower) continue;
    const body = String(item.body || '');
    let match;
    MARKER_SCAN_RE.lastIndex = 0;
    while ((match = MARKER_SCAN_RE.exec(body)) !== null) {
      const foundKey = match[1];
      const foundOp = match[2] || '';
      if (foundKey === identity.key) {
        if (foundOp) {
          if (foundOp === identity.opHash) {
            return { status: 'MATCH', existingId: String(item.id) };
          }
          return { status: 'COLLISION', existingId: String(item.id), existingOp: foundOp };
        }
        // Legacy marker without ;op= -> compare normalized body text only when allowed (summary/reply).
        if (allowLegacyFallback && stripMarkers(body) === expectedStripped) {
          return { status: 'MATCH', existingId: String(item.id) };
        }
        return { status: 'COLLISION', existingId: String(item.id), existingOp: 'legacy-mismatch' };
      }
      if (foundOp && foundOp === identity.opHash) {
        return { status: 'MATCH', existingId: String(item.id) };
      }
    }
  }
  return { status: 'NONE' };
}

function runPostWriteGuarded(statePath, ctx, fn) {
  try {
    return fn();
  } catch (err) {
    if (err instanceof B3Exit && (err.payload?.status === 'PR_POST_WRITE_UNVERIFIED' || err.payload?.status === 'PR_POST_WRITE_HEAD_MOVED')) {
      throw err;
    }
    const reason = err instanceof B3Exit ? `${err.payload?.status}: ${err.payload?.error}` : sanitizeUntrustedText(err?.message || String(err)).slice(0, 240);
    recordAuditState(statePath, {
      action: ctx.action,
      status: 'PR_POST_WRITE_UNVERIFIED',
      reconciliation_required: true,
      repo: ctx.repo,
      pr: ctx.pr,
      ...(ctx.extra || {}),
      detail: reason
    }, { critical: false });
    fail(
      'PR_POST_WRITE_UNVERIFIED',
      `Post-write verification interrupted after mutation (${reason}); reconcile remote state before retrying`,
      EXIT_ERROR,
      { outcome: 'mutated_unverified', mutated: true, reconciliation_required: true, ...(ctx.extra || {}) }
    );
  }
}

// --- R006: Unified diff anchor parser ---
function parseUnifiedDiffAnchors(patch) {
  if (typeof patch !== 'string' || !patch.trim()) {
    return null;
  }
  const rightLines = new Set();
  const leftLines = new Set();
  let leftLine = 0;
  let rightLine = 0;
  let sawHunk = false;
  for (const rawLine of patch.split(/\r?\n/)) {
    const hunkMatch = rawLine.match(/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/);
    if (hunkMatch) {
      sawHunk = true;
      leftLine = Number.parseInt(hunkMatch[1], 10);
      rightLine = Number.parseInt(hunkMatch[2], 10);
      continue;
    }
    if (!sawHunk) continue;
    if (rawLine.startsWith('+')) {
      rightLines.add(rightLine);
      rightLine += 1;
    } else if (rawLine.startsWith('-')) {
      leftLines.add(leftLine);
      leftLine += 1;
    } else if (rawLine.startsWith(' ')) {
      leftLines.add(leftLine);
      rightLines.add(rightLine);
      leftLine += 1;
      rightLine += 1;
    }
  }
  return sawHunk ? { rightLines, leftLines } : null;
}

// --- R001: Verification evidence & b3-verify-v1 receipt validator ---
function parseVerifyReceipt(receiptText) {
  const map = {};
  for (const rawLine of receiptText.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;
    const eq = line.indexOf('=');
    if (eq <= 0) continue;
    const k = line.slice(0, eq).trim();
    const v = line.slice(eq + 1).trim();
    map[k] = v;
  }
  return map;
}

function pathMatchesRelevant(targetPath, relevantPaths) {
  const normTarget = targetPath.replace(/\\/g, '/');
  for (const rp of relevantPaths) {
    const clean = rp.trim().replace(/\\/g, '/').replace(/\/+$/, '');
    if (!clean) continue;
    if (normTarget === clean || normTarget.startsWith(`${clean}/`)) {
      return true;
    }
  }
  return false;
}

function parseAndValidateEvidenceFile(evidencePath, repoFull, prNumber, expectedHead, threadId, fixCommit) {
  const raw = readSafeInputFile(evidencePath, '--evidence-file');
  let ev;
  try {
    ev = JSON.parse(raw);
  } catch {
    fail('PR_VERIFY_REQUIRED', '--evidence-file is not valid JSON', EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
  }
  if (!ev || typeof ev !== 'object' || ev.schema !== 'b3-pr-verify-evidence-v1') {
    fail('PR_VERIFY_REQUIRED', 'Evidence schema must be b3-pr-verify-evidence-v1', EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
  }
  if (String(ev.repo || '').toLowerCase() !== repoFull.toLowerCase()) {
    fail('PR_VERIFY_REQUIRED', `Evidence repo (${ev.repo}) does not match ${repoFull}`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
  }
  if (Number(ev.pr) !== prNumber) {
    fail('PR_VERIFY_REQUIRED', `Evidence PR (${ev.pr}) does not match #${prNumber}`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
  }
  if (String(ev.head_sha || '').toLowerCase() !== expectedHead) {
    fail('PR_VERIFY_REQUIRED', `Evidence head_sha (${ev.head_sha}) does not match expected HEAD (${expectedHead})`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
  }
  if (String(ev.thread_id || '') !== threadId) {
    fail('PR_VERIFY_REQUIRED', `Evidence thread_id (${ev.thread_id}) does not match ${threadId}`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
  }
  if (String(ev.fix_commit || '').toLowerCase() !== fixCommit) {
    fail('PR_VERIFY_REQUIRED', `Evidence fix_commit (${ev.fix_commit}) does not match ${fixCommit}`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
  }
  const basis = String(ev.resolution_basis || '');
  if (!ALLOWED_BASES.has(basis)) {
    fail('PR_VERIFY_REQUIRED', `Invalid evidence resolution_basis (${basis})`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
  }
  let primaryThreadId = '';
  if (basis === 'DUPLICATE_FIXED') {
    primaryThreadId = String(ev.primary_thread_id || '');
    if (!ID_RE.test(primaryThreadId) || primaryThreadId === threadId) {
      fail('PR_VERIFY_REQUIRED', 'DUPLICATE_FIXED evidence requires a distinct valid primary_thread_id', EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
    }
  }
  const targetPath = String(ev.target_path || '').trim();
  if (!targetPath || hasControlChars(targetPath) || targetPath.includes('\\') || targetPath.split('/').includes('..')) {
    fail('PR_VERIFY_REQUIRED', 'Evidence requires valid target_path', EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
  }
  const fixedPaths = Array.isArray(ev.fixed_paths)
    ? ev.fixed_paths.map((p) => String(p || '').trim()).filter(Boolean)
    : [];
  for (const fp of fixedPaths) {
    if (hasControlChars(fp) || fp.includes('\\') || fp.split('/').includes('..')) {
      fail('PR_VERIFY_REQUIRED', `Invalid fixed_paths entry in evidence: ${fp}`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
    }
  }
  const summary = String(ev.summary || '').trim();
  const checkedCmd = String(ev.checked_command || '').trim();
  if (summary.length < 10 || !checkedCmd) {
    fail('PR_VERIFY_REQUIRED', 'Evidence requires non-empty checked_command and descriptive summary', EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
  }

  // Validate raw verify_receipt_path BEFORE path.resolve so .. traversal / drive-relative / UNC cannot be collapsed away.
  const receiptRel = String(ev.verify_receipt_path || '').trim();
  if (!receiptRel) {
    fail('PR_VERIFY_REQUIRED', 'Evidence requires verify_receipt_path pointing to a b3-verify-v1 receipt', EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
  }
  validateRawPathSyntax(receiptRel, 'verify_receipt_path', true);
  const receiptFullPath = path.isAbsolute(receiptRel)
    ? receiptRel
    : path.resolve(path.dirname(path.resolve(evidencePath)), receiptRel);
  const receiptText = readSafeInputFile(receiptFullPath, 'verify_receipt_path');
  const receipt = parseVerifyReceipt(receiptText);
  if (receipt.schema !== 'b3-verify-v1') {
    fail('PR_VERIFY_REQUIRED', `Receipt schema must be b3-verify-v1 (got ${receipt.schema || 'missing'})`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
  }
  if (receipt.status !== 'PASS' || receipt.exit_code !== '0') {
    fail('PR_VERIFY_REQUIRED', `Verification receipt did not pass (status=${receipt.status}, exit_code=${receipt.exit_code})`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
  }
  if (!SHA_RE.test(receipt.head_sha || '') || receipt.head_sha.toLowerCase() !== expectedHead) {
    fail('PR_VERIFY_REQUIRED', `Verification receipt head_sha (${receipt.head_sha || 'missing'}) is stale vs expected HEAD (${expectedHead})`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
  }
  if (!SHA_RE.test(receipt.tree_hash || '')) {
    fail('PR_VERIFY_REQUIRED', 'Verification receipt missing valid 40-hex tree_hash', EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
  }
  if (!receipt.command || !receipt.timestamp_utc || Number.isNaN(Date.parse(receipt.timestamp_utc))) {
    fail('PR_VERIFY_REQUIRED', 'Verification receipt missing valid command or timestamp_utc', EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
  }
  if (receipt.log_path && receipt.log_path !== 'none') {
    validateRawPathSyntax(receipt.log_path, 'receipt.log_path', true);
  }
  const receiptScope = String(receipt.scope || '').toLowerCase();
  const rawRelPaths = String(receipt.relevant_paths || '').trim();
  const relevantPaths = rawRelPaths && rawRelPaths.toLowerCase() !== 'all'
    ? rawRelPaths.split(',').map((s) => s.trim()).filter(Boolean)
    : [];
  const receiptCoversAll = receiptScope === 'full' || rawRelPaths.toLowerCase() === 'all' || relevantPaths.includes('.');
  const checkPaths = fixedPaths.length > 0 ? fixedPaths : [targetPath];
  if (!receiptCoversAll) {
    const allCovered = checkPaths.every((p) => pathMatchesRelevant(p, relevantPaths));
    if (!allCovered) {
      fail('PR_VERIFY_REQUIRED', `Verification receipt relevant_paths (${rawRelPaths || 'none'}) does not cover all target/fix paths (${checkPaths.join(', ')})`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
    }
  }

  return {
    basis,
    primaryThreadId,
    targetPath,
    fixedPaths: checkPaths,
    hasExplicitFixedPaths: fixedPaths.length > 0,
    receiptCoversAll,
    relevantPaths,
    checkedCommand: checkedCmd,
    receiptCommand: receipt.command,
    receiptHeadSha: receipt.head_sha.toLowerCase(),
    receiptTreeHash: receipt.tree_hash.toLowerCase(),
    receiptTimestamp: receipt.timestamp_utc
  };
}

// --- Subcommand 1: fetch (R008: metadata-first + targeted --thread-id) ---
function handleFetch(flags) {
  const repo = validateRepo(flags.repo);
  const prNumber = validatePr(flags.pr);
  const maxPages = validateMaxPages(flags['max-pages']);
  const includeResolved = Boolean(flags['include-resolved']);
  const includeBodies = Boolean(flags['include-bodies']);
  const selectedThreadIds = flags['thread-id'] ? validateThreadIdList(flags['thread-id']) : [];
  const statePath = flags['state-file'] ? validateSafeFilePath(flags['state-file'], '--state-file', { mustExist: false, rejectTraversal: true }) : '';

  if (selectedThreadIds.length > 0) {
    // R008: targeted single/multi-thread retrieval without fetching all PR threads.
    const header = fetchPrHeader(repo.owner, repo.name, prNumber);
    const fetchedThreads = [];
    for (const tid of selectedThreadIds) {
      const t = fetchSingleReviewThread(repo.full, prNumber, tid, maxPages, true);
      if (!t) {
        fail('PR_TARGET_MISMATCH', `Review thread ${tid} does not belong to ${repo.full}#${prNumber}`, EXIT_ERROR);
      }
      fetchedThreads.push({
        id: t.id,
        target_kind: 'review_thread',
        is_resolved: t.isResolved,
        is_outdated: t.isOutdated,
        path: frameUntrustedText(t.path),
        line: t.line,
        comment_count: t.comments.length,
        authors: [...new Set(t.comments.map((c) => c.author))].map((a) => frameUntrustedText(a)),
        comments: t.comments.map((c) => ({
          id: c.id,
          author: frameUntrustedText(c.author),
          body: frameUntrustedText(c.body)
        }))
      });
    }
    // Do NOT clear PR-wide reconciliation on partial --thread-id fetch; require full PR fetch.
    emit({
      status: 'PR_FETCH_OK',
      retrieval_mode: 'targeted_threads',
      repo: repo.full,
      pr: prNumber,
      viewer: header.viewer,
      untrusted_data_framed: true,
      pull_request: {
        number: prNumber,
        state: header.state,
        head_sha: header.headSha
      },
      counts: {
        returned_review_threads: fetchedThreads.length,
        general_comments: 0
      },
      review_threads: fetchedThreads,
      general_comments: []
    }, EXIT_OK);
  }

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
      comment_count: t.totalCount,
      authors
    };
    if (includeBodies) {
      obj.comments = t.comments.map((c) => ({
        id: c.id,
        author: frameUntrustedText(c.author),
        body: frameUntrustedText(c.body)
      }));
    } else if (t.hasMoreNestedComments) {
      obj.nested_comments_omitted = true;
    }
    return obj;
  });

  const formattedGeneral = rawIssueComments.map((c) => {
    const obj = {
      id: String(c.id),
      target_kind: 'general_comment',
      resolvable: false,
      html_url: c.html_url ? String(c.html_url) : null,
      author: frameUntrustedText(c.user?.login ? c.user.login : 'unknown')
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

  clearReconciliationFlag(statePath, repo.full, prNumber, prMeta.headSha);
  emit({
    status: 'PR_FETCH_OK',
    retrieval_mode: includeBodies ? 'full_with_bodies' : 'metadata_first',
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

// --- Subcommand 2: reply (R003, R004, R005, R008, R009) ---
function formatGeneralReplyWithRef(rawBody, targetId, htmlUrl) {
  const clean = normalizeText(rawBody);
  const alreadyHasRef = (htmlUrl && clean.includes(htmlUrl)) || clean.includes(`#issuecomment-${targetId}`);
  if (alreadyHasRef) return clean;
  const refLine = htmlUrl && /^https?:\/\//i.test(htmlUrl)
    ? `> Replying to [comment #${targetId}](${htmlUrl})`
    : `> Replying to comment #${targetId} (#issuecomment-${targetId})`;
  return `${refLine}\n\n${clean}`;
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
  const explicitKey = validateKey(flags['idempotency-key']);
  const maxPages = validateMaxPages(flags['max-pages']);
  const statePath = flags['state-file'] ? validateSafeFilePath(flags['state-file'], '--state-file', { mustExist: false, rejectTraversal: true }) : '';
  const isDraft = Boolean(flags.draft);
  const authWrite = Boolean(flags['authorize-write']);

  if (isDraft && authWrite) {
    fail('PR_INVALID_ARGS', '--draft cannot be combined with --authorize-write', EXIT_ERROR);
  }
  if (isDraft) {
    const previewBase = targetKind === 'general_comment' ? formatGeneralReplyWithRef(rawBody, targetId, null) : normalizeText(rawBody);
    const draftIdentity = computeOperationIdentity({
      repo: repo.full, pr: prNumber, actor: 'draft', op: 'reply', targetKind, targetId, reviewedSha: expectedHead, normalizedPayload: previewBase, explicitKey
    });
    const preview = appendMarker(previewBase, draftIdentity.marker);
    if (preview.length > MAX_BODY_CHARS) {
      fail('PR_FILE_GUARD', `Reply body exceeds ${MAX_BODY_CHARS} chars`, EXIT_ERROR);
    }
    emit({
      status: 'PR_DRAFT_OK',
      action: 'reply',
      mutated: false,
      repo: repo.full,
      pr: prNumber,
      expected_head: expectedHead,
      target_kind: targetKind,
      target_id: targetId,
      idempotency_key: draftIdentity.key,
      operation_hash: draftIdentity.opHash,
      body_preview: preview
    }, EXIT_OK);
  }
  if (!authWrite) {
    fail('PR_AUTH_REQUIRED', 'Explicit --authorize-write is required to post a PR reply (or use --draft)', EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
  }

  return withStateLock(statePath, () => {
    assertNoPendingReconciliation(statePath, repo.full, prNumber);
    const header = fetchPrHeader(repo.owner, repo.name, prNumber);
    assertOpenAndFreshHead(header, expectedHead);

    if (targetKind === 'review_thread') {
      // R008: targeted single-thread retrieval only.
      const thread = fetchSingleReviewThread(repo.full, prNumber, targetId, maxPages, true);
      if (!thread) {
        fail('PR_TARGET_MISMATCH', `Review thread ${targetId} does not belong to ${repo.full}#${prNumber}`, EXIT_ERROR);
      }
      const normalizedBody = normalizeText(rawBody);
      const identity = computeOperationIdentity({
        repo: repo.full, pr: prNumber, actor: header.viewer, op: 'reply', targetKind, targetId, reviewedSha: expectedHead, normalizedPayload: normalizedBody, explicitKey
      });
      const finalBody = appendMarker(normalizedBody, identity.marker);
      if (finalBody.length > MAX_BODY_CHARS) {
        fail('PR_FILE_GUARD', `Reply body exceeds ${MAX_BODY_CHARS} chars`, EXIT_ERROR);
      }

      const idem = scanRemoteIdempotency(thread.comments, header.viewer, identity, normalizedBody);
      if (idem.status === 'COLLISION') {
        fail('PR_KEY_COLLISION', `Idempotency key ${identity.key} already used for a different operation on ${targetId} (comment ${idem.existingId})`, EXIT_BLOCKED, {
          outcome: 'blocked_before_write', mutated: false, existing_comment_id: idem.existingId, key: identity.key
        });
      }
      if (idem.status === 'MATCH') {
        recordAuditState(statePath, { action: 'reply', status: 'PR_IDEMPOTENT_SKIP', repo: repo.full, pr: prNumber, target_kind: targetKind, target_id: targetId, key: identity.key, op_hash: identity.opHash, comment_id: idem.existingId });
        emit({ status: 'PR_IDEMPOTENT_SKIP', action: 'reply', mutated: false, target_kind: targetKind, target_id: targetId, key: identity.key, operation_hash: identity.opHash, existing_comment_id: idem.existingId }, EXIT_OK);
      }

      // R004: immediate pre-write freshness recheck after all reads.
      recheckFreshBeforeMutation(repo.owner, repo.name, prNumber, expectedHead);
      recordAuditState(statePath, { action: 'reply', status: 'PENDING', repo: repo.full, pr: prNumber, target_kind: targetKind, target_id: targetId, key: identity.key, op_hash: identity.opHash }, { critical: true });

      const mut = `
        mutation($threadId: ID!, $body: String!) {
          addPullRequestReviewThreadReply(input: { pullRequestReviewThreadId: $threadId, body: $body }) {
            comment { id url }
          }
        }
      `;
      const res = runPostWriteGuarded(statePath, { action: 'reply', repo: repo.full, pr: prNumber, extra: { target_id: targetId, key: identity.key } }, () => ghGraphQL(mut, { threadId: targetId, body: finalBody }));
      const created = res.addPullRequestReviewThreadReply?.comment;
      if (!created || !created.id) {
        recordAuditState(statePath, { action: 'reply', status: 'PR_POST_WRITE_UNVERIFIED', reconciliation_required: true, repo: repo.full, pr: prNumber, target_id: targetId, key: identity.key }, { critical: false });
        fail('PR_POST_WRITE_UNVERIFIED', 'Thread reply did not return a created comment ID', EXIT_ERROR, { outcome: 'mutated_unverified', mutated: true, reconciliation_required: true });
      }
      const createdId = String(created.id);

      // R009 + R004: verify actual created comment object, actor, content, target, PR state & HEAD.
      const verifyQuery = `
        query($owner: String!, $repo: String!, $pr: Int!, $threadId: ID!, $commentId: ID!) {
          repository(owner: $owner, name: $repo) { pullRequest(number: $pr) { state headRefOid } }
          thread: node(id: $threadId) { ... on PullRequestReviewThread { id isResolved } }
          comment: node(id: $commentId) {
            ... on PullRequestReviewComment {
              id
              author { login }
              body
              pullRequest { number }
            }
          }
        }
      `;
      const vData = runPostWriteGuarded(statePath, { action: 'reply', repo: repo.full, pr: prNumber, extra: { target_id: targetId, comment_id: createdId, key: identity.key } }, () => ghGraphQL(verifyQuery, { owner: repo.owner, repo: repo.name, pr: prNumber, threadId: targetId, commentId: createdId }));
      const vComment = vData.comment;
      const vThread = vData.thread;
      const postState = String(vData.repository?.pullRequest?.state || '');
      const postHead = String(vData.repository?.pullRequest?.headRefOid || '').toLowerCase();
      const authorOk = String(vComment?.author?.login || '').toLowerCase() === header.viewer.toLowerCase();
      const bodyOk = String(vComment?.body || '').includes(identity.marker) && stripMarkers(vComment?.body || '') === stripMarkers(normalizedBody);
      const prOk = Number(vComment?.pullRequest?.number) === prNumber;
      const threadOk = Boolean(vThread && String(vThread.id) === targetId);

      if (!vComment || String(vComment.id) !== createdId || !authorOk || !bodyOk || !prOk || !threadOk) {
        recordAuditState(statePath, { action: 'reply', status: 'PR_POST_WRITE_UNVERIFIED', reconciliation_required: true, repo: repo.full, pr: prNumber, target_id: targetId, comment_id: createdId, key: identity.key }, { critical: false });
        fail('PR_POST_WRITE_UNVERIFIED', `Post-write verification failed for thread reply ${createdId} (authorOk=${authorOk}, bodyOk=${bodyOk}, prOk=${prOk}, threadOk=${threadOk})`, EXIT_ERROR, {
          outcome: 'mutated_unverified', mutated: true, reconciliation_required: true, comment_id: createdId
        });
      }
      if (postHead !== expectedHead || postState !== 'OPEN') {
        recordAuditState(statePath, { action: 'reply', status: 'PR_POST_WRITE_HEAD_MOVED', reconciliation_required: true, repo: repo.full, pr: prNumber, target_id: targetId, comment_id: createdId, expected_head: expectedHead, remote_head: postHead, remote_state: postState }, { critical: false });
        fail('PR_POST_WRITE_HEAD_MOVED', `PR state/HEAD changed concurrently after reply (state=${postState}, head=${expectedHead} -> ${postHead})`, EXIT_BLOCKED, {
          outcome: 'mutated_but_stale', mutated: true, reconciliation_required: true, comment_id: createdId, expected_head: expectedHead, remote_head: postHead, remote_state: postState
        });
      }

      recordAuditState(statePath, { action: 'reply', status: 'PR_REPLY_OK', repo: repo.full, pr: prNumber, target_kind: targetKind, target_id: targetId, key: identity.key, op_hash: identity.opHash, comment_id: createdId, head_sha: postHead });
      emit({
        status: 'PR_REPLY_OK',
        action: 'reply',
        mutated: true,
        repo: repo.full,
        pr: prNumber,
        target_kind: targetKind,
        target_id: targetId,
        comment_id: createdId,
        idempotency_key: identity.key,
        operation_hash: identity.opHash,
        verified_remote: true,
        verified_head: postHead
      }, EXIT_OK);
    } else {
      // R005 + R008: verify target general comment directly & include reliable permalink/reference.
      const targetRes = ghRestGet(`repos/${repo.full}/issues/comments/${targetId}`, { allowNotFound: true });
      const targetObj = targetRes.data;
      const issueUrl = String(targetObj?.issue_url || '');
      if (targetRes.notFound || !targetObj || String(targetObj.id) !== targetId || !issueUrl.endsWith(`/issues/${prNumber}`)) {
        fail('PR_TARGET_MISMATCH', `General PR comment ${targetId} does not belong to ${repo.full}#${prNumber}`, EXIT_ERROR);
      }
      const targetUrl = targetObj.html_url ? String(targetObj.html_url) : null;
      const referencedBody = formatGeneralReplyWithRef(rawBody, targetId, targetUrl);
      const identity = computeOperationIdentity({
        repo: repo.full, pr: prNumber, actor: header.viewer, op: 'reply', targetKind, targetId, reviewedSha: expectedHead, normalizedPayload: referencedBody, explicitKey
      });
      const finalBody = appendMarker(referencedBody, identity.marker);
      if (finalBody.length > MAX_BODY_CHARS) {
        fail('PR_FILE_GUARD', `Reply body exceeds ${MAX_BODY_CHARS} chars`, EXIT_ERROR);
      }

      const comments = fetchRestPaginated(`repos/${repo.full}/issues/${prNumber}/comments`, maxPages);
      const idem = scanRemoteIdempotency(
        comments.map((c) => ({ id: c.id, author: c.user?.login || '', body: c.body || '' })),
        header.viewer,
        identity,
        referencedBody
      );
      if (idem.status === 'COLLISION') {
        fail('PR_KEY_COLLISION', `Idempotency key ${identity.key} already used for a different operation on PR #${prNumber} (comment ${idem.existingId})`, EXIT_BLOCKED, {
          outcome: 'blocked_before_write', mutated: false, existing_comment_id: idem.existingId, key: identity.key
        });
      }
      if (idem.status === 'MATCH') {
        recordAuditState(statePath, { action: 'reply', status: 'PR_IDEMPOTENT_SKIP', repo: repo.full, pr: prNumber, target_kind: targetKind, target_id: targetId, key: identity.key, op_hash: identity.opHash, comment_id: idem.existingId });
        emit({ status: 'PR_IDEMPOTENT_SKIP', action: 'reply', mutated: false, target_kind: targetKind, target_id: targetId, key: identity.key, operation_hash: identity.opHash, existing_comment_id: idem.existingId }, EXIT_OK);
      }

      // R004: immediate pre-write freshness recheck.
      recheckFreshBeforeMutation(repo.owner, repo.name, prNumber, expectedHead);
      recordAuditState(statePath, { action: 'reply', status: 'PENDING', repo: repo.full, pr: prNumber, target_kind: targetKind, target_id: targetId, key: identity.key, op_hash: identity.opHash }, { critical: true });

      const created = runPostWriteGuarded(statePath, { action: 'reply', repo: repo.full, pr: prNumber, extra: { target_id: targetId, key: identity.key } }, () => ghRestPost(`repos/${repo.full}/issues/${prNumber}/comments`, { body: finalBody }));
      if (!created || !created.id) {
        recordAuditState(statePath, { action: 'reply', status: 'PR_POST_WRITE_UNVERIFIED', reconciliation_required: true, repo: repo.full, pr: prNumber, target_id: targetId, key: identity.key }, { critical: false });
        fail('PR_POST_WRITE_UNVERIFIED', 'General PR comment reply did not return a created comment ID', EXIT_ERROR, { outcome: 'mutated_unverified', mutated: true, reconciliation_required: true });
      }
      const createdId = String(created.id);

      // R009 + R004: re-fetch created issue comment & verify actor, PR association, content, state & HEAD.
      const { vRes, postHeader } = runPostWriteGuarded(statePath, { action: 'reply', repo: repo.full, pr: prNumber, extra: { target_id: targetId, comment_id: createdId, key: identity.key } }, () => ({
        vRes: ghRestGet(`repos/${repo.full}/issues/comments/${createdId}`, { allowNotFound: true }),
        postHeader: fetchPrHeader(repo.owner, repo.name, prNumber)
      }));
      const vComment = vRes.data;
      const authorOk = String(vComment?.user?.login || '').toLowerCase() === header.viewer.toLowerCase();
      const prOk = String(vComment?.issue_url || '').endsWith(`/issues/${prNumber}`);
      const bodyOk = String(vComment?.body || '').includes(identity.marker) && stripMarkers(vComment?.body || '') === stripMarkers(referencedBody);

      if (vRes.notFound || !vComment || String(vComment.id) !== createdId || !authorOk || !prOk || !bodyOk) {
        recordAuditState(statePath, { action: 'reply', status: 'PR_POST_WRITE_UNVERIFIED', reconciliation_required: true, repo: repo.full, pr: prNumber, target_id: targetId, comment_id: createdId, key: identity.key }, { critical: false });
        fail('PR_POST_WRITE_UNVERIFIED', `Post-write verification failed for general comment ${createdId} (authorOk=${authorOk}, prOk=${prOk}, bodyOk=${bodyOk})`, EXIT_ERROR, {
          outcome: 'mutated_unverified', mutated: true, reconciliation_required: true, comment_id: createdId
        });
      }
      if (postHeader.headSha !== expectedHead || postHeader.state !== 'OPEN') {
        recordAuditState(statePath, { action: 'reply', status: 'PR_POST_WRITE_HEAD_MOVED', reconciliation_required: true, repo: repo.full, pr: prNumber, target_id: targetId, comment_id: createdId, expected_head: expectedHead, remote_head: postHeader.headSha, remote_state: postHeader.state }, { critical: false });
        fail('PR_POST_WRITE_HEAD_MOVED', `PR state/HEAD changed concurrently after reply (state=${postHeader.state}, head=${expectedHead} -> ${postHeader.headSha})`, EXIT_BLOCKED, {
          outcome: 'mutated_but_stale', mutated: true, reconciliation_required: true, comment_id: createdId, expected_head: expectedHead, remote_head: postHeader.headSha, remote_state: postHeader.state
        });
      }

      recordAuditState(statePath, { action: 'reply', status: 'PR_REPLY_OK', repo: repo.full, pr: prNumber, target_kind: targetKind, target_id: targetId, key: identity.key, op_hash: identity.opHash, comment_id: createdId, head_sha: postHeader.headSha });
      emit({
        status: 'PR_REPLY_OK',
        action: 'reply',
        mutated: true,
        repo: repo.full,
        pr: prNumber,
        target_kind: targetKind,
        target_id: targetId,
        referenced_url: targetUrl,
        comment_id: createdId,
        idempotency_key: identity.key,
        operation_hash: identity.opHash,
        verified_remote: true,
        verified_head: postHeader.headSha
      }, EXIT_OK);
    }
  });
}

// --- Subcommand 3: resolve (R001, R004, R008, R009) ---
function handleResolve(flags) {
  const repo = validateRepo(flags.repo);
  const prNumber = validatePr(flags.pr);
  const expectedHead = validateSha(flags['expected-head'], '--expected-head');
  const threadId = validateId(flags['thread-id'], '--thread-id');
  const fixCommit = validateSha(flags['fix-commit'], '--fix-commit');
  const maxPages = validateMaxPages(flags['max-pages']);
  const statePath = flags['state-file'] ? validateSafeFilePath(flags['state-file'], '--state-file', { mustExist: false, rejectTraversal: true }) : '';
  const isDraft = Boolean(flags.draft);
  const authResolve = Boolean(flags['authorize-resolve']);

  if (isDraft && authResolve) {
    fail('PR_INVALID_ARGS', '--draft cannot be combined with --authorize-resolve', EXIT_ERROR);
  }
  if (/^[0-9]+$/.test(threadId) || threadId.startsWith('IC_')) {
    fail('PR_NOT_RESOLVABLE', `General PR comments (${threadId}) cannot be resolved as review threads`, EXIT_ERROR);
  }
  if (!flags['evidence-file']) {
    fail('PR_VERIFY_REQUIRED', '--evidence-file (bound to repo, PR, HEAD, thread, fix commit, and passing b3-verify-v1 receipt) is required', EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
  }
  const evidence = parseAndValidateEvidenceFile(flags['evidence-file'], repo.full, prNumber, expectedHead, threadId, fixCommit);

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
      evidence_basis: evidence.basis,
      target_path: evidence.targetPath,
      receipt_head_sha: evidence.receiptHeadSha
    }, EXIT_OK);
  }
  if (!authResolve) {
    fail('PR_AUTH_REQUIRED', 'Explicit --authorize-resolve is required to resolve a review thread (or use --draft)', EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
  }

  return withStateLock(statePath, () => {
    assertNoPendingReconciliation(statePath, repo.full, prNumber);
    const header = fetchPrHeader(repo.owner, repo.name, prNumber);
    assertOpenAndFreshHead(header, expectedHead);

    // R008: targeted single-thread retrieval only (no full-PR thread scan).
    const thread = fetchSingleReviewThread(repo.full, prNumber, threadId, maxPages, false);
    if (!thread) {
      const genCheck = ghRestGet(`repos/${repo.full}/issues/comments/${threadId}`, { allowNotFound: true });
      if (!genCheck.notFound && genCheck.data && String(genCheck.data.issue_url || '').endsWith(`/issues/${prNumber}`)) {
        fail('PR_NOT_RESOLVABLE', `Target ${threadId} is a general PR comment and cannot be resolved`, EXIT_ERROR);
      }
      fail('PR_TARGET_MISMATCH', `Review thread ${threadId} does not belong to ${repo.full}#${prNumber}`, EXIT_ERROR);
    }

    // R001: bind evidence target_path to actual remote thread path.
    if (!thread.path || evidence.targetPath !== thread.path) {
      fail('PR_VERIFY_REQUIRED', `Evidence target_path (${evidence.targetPath}) does not match thread path (${thread.path || 'missing'})`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
    }

    // Prove fix_commit is an ancestor of remote PR HEAD.
    const cmp = ghRestGet(`repos/${repo.full}/compare/${fixCommit}...${header.headSha}`, { allowNotFound: true });
    if (cmp.notFound || !cmp.data || typeof cmp.data !== 'object') {
      fail('PR_FIX_NOT_REMOTE', `Fix commit ${fixCommit} was not found on remote ${repo.full}`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
    }
    const cmpStatus = String(cmp.data.status || '');
    const behindBy = Number(cmp.data.behind_by ?? -1);
    if (!(cmpStatus === 'identical' || (cmpStatus === 'ahead' && behindBy === 0))) {
      fail('PR_FIX_NOT_REMOTE', `Fix commit ${fixCommit} is not reachable in remote PR HEAD ${header.headSha} (compare status=${cmpStatus}, behind_by=${behindBy})`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
    }

    // R001: DUPLICATE_FIXED must remotely verify primary_thread_id exists on this PR and is resolved.
    if (evidence.basis === 'DUPLICATE_FIXED') {
      const primaryThread = fetchSingleReviewThread(repo.full, prNumber, evidence.primaryThreadId, maxPages, false);
      if (!primaryThread || !primaryThread.isResolved) {
        fail('PR_VERIFY_REQUIRED', `DUPLICATE_FIXED primary_thread_id (${evidence.primaryThreadId}) must exist on ${repo.full}#${prNumber} and be resolved first`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
      }
    }

    // R001: ancestry alone does not prove fix relevance — verify remote fix_commit modified ALL declared fix paths
    // (or thread.path when fixed_paths omitted) AND every such path is covered by the passing b3-verify-v1 receipt.
    const commitRes = ghRestGet(`repos/${repo.full}/commits/${fixCommit}`, { allowNotFound: true });
    const commitFiles = Array.isArray(commitRes.data?.files) ? commitRes.data.files : [];
    const touchedSet = new Set();
    for (const f of commitFiles) {
      if (f?.filename) touchedSet.add(String(f.filename));
      if (f?.previous_filename) touchedSet.add(String(f.previous_filename));
    }
    const pathsToProve = evidence.hasExplicitFixedPaths ? evidence.fixedPaths : [thread.path];
    const allPathsTouchedAndVerified = pathsToProve.length > 0 && pathsToProve.every(
      (p) => touchedSet.has(p) && (evidence.receiptCoversAll || pathMatchesRelevant(p, evidence.relevantPaths))
    );
    if (commitRes.notFound || !allPathsTouchedAndVerified) {
      fail('PR_VERIFY_REQUIRED', `Fix commit ${fixCommit} and verification receipt do not jointly cover required paths (${pathsToProve.join(', ')})`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
    }

    if (thread.isResolved) {
      recordAuditState(statePath, { action: 'resolve', status: 'PR_ALREADY_RESOLVED', repo: repo.full, pr: prNumber, thread_id: threadId, fix_commit: fixCommit });
      emit({ status: 'PR_ALREADY_RESOLVED', action: 'resolve', mutated: false, thread_id: threadId, verified_head: header.headSha }, EXIT_OK);
    }

    // R004: immediate pre-write freshness recheck.
    recheckFreshBeforeMutation(repo.owner, repo.name, prNumber, expectedHead);
    recordAuditState(statePath, { action: 'resolve', status: 'PENDING', repo: repo.full, pr: prNumber, thread_id: threadId, fix_commit: fixCommit }, { critical: true });

    const mut = `
      mutation($threadId: ID!) {
        resolveReviewThread(input: { threadId: $threadId }) {
          thread { id isResolved }
        }
      }
    `;
    const res = runPostWriteGuarded(statePath, { action: 'resolve', repo: repo.full, pr: prNumber, extra: { thread_id: threadId } }, () => ghGraphQL(mut, { threadId }));
    const mutatedThread = res.resolveReviewThread?.thread;
    if (!mutatedThread || !mutatedThread.isResolved) {
      recordAuditState(statePath, { action: 'resolve', status: 'PR_POST_WRITE_UNVERIFIED', reconciliation_required: true, repo: repo.full, pr: prNumber, thread_id: threadId }, { critical: false });
      fail('PR_POST_WRITE_UNVERIFIED', 'resolveReviewThread did not confirm isResolved=true', EXIT_ERROR, { outcome: 'mutated_unverified', mutated: true, reconciliation_required: true, thread_id: threadId });
    }

    // R009 + R004: re-verify resolved thread ownership, state, PR OPEN & HEAD remotely.
    const verifyQuery = `
      query($owner: String!, $repo: String!, $pr: Int!, $threadId: ID!) {
        repository(owner: $owner, name: $repo) {
          pullRequest(number: $pr) { state headRefOid }
        }
        node(id: $threadId) {
          ... on PullRequestReviewThread {
            id
            isResolved
            pullRequest { number repository { nameWithOwner } }
          }
        }
      }
    `;
    const vData = runPostWriteGuarded(statePath, { action: 'resolve', repo: repo.full, pr: prNumber, extra: { thread_id: threadId } }, () => ghGraphQL(verifyQuery, { owner: repo.owner, repo: repo.name, pr: prNumber, threadId }));
    const postState = String(vData.repository?.pullRequest?.state || '');
    const postHead = String(vData.repository?.pullRequest?.headRefOid || '').toLowerCase();
    const vThread = vData.node;
    const ownerRepo = String(vThread?.pullRequest?.repository?.nameWithOwner || '').toLowerCase();
    const ownerOk = ownerRepo === repo.full.toLowerCase() && Number(vThread?.pullRequest?.number) === prNumber;

    if (!vThread || String(vThread.id) !== threadId || !vThread.isResolved || !ownerOk) {
      recordAuditState(statePath, { action: 'resolve', status: 'PR_POST_WRITE_UNVERIFIED', reconciliation_required: true, repo: repo.full, pr: prNumber, thread_id: threadId }, { critical: false });
      fail('PR_POST_WRITE_UNVERIFIED', `Post-write verification failed: thread ${threadId} is not confirmed resolved on ${repo.full}#${prNumber}`, EXIT_ERROR, {
        outcome: 'mutated_unverified', mutated: true, reconciliation_required: true, thread_id: threadId
      });
    }
    if (postHead !== expectedHead || postState !== 'OPEN') {
      recordAuditState(statePath, { action: 'resolve', status: 'PR_POST_WRITE_HEAD_MOVED', reconciliation_required: true, repo: repo.full, pr: prNumber, thread_id: threadId, expected_head: expectedHead, remote_head: postHead, remote_state: postState }, { critical: false });
      fail('PR_POST_WRITE_HEAD_MOVED', `PR state/HEAD changed concurrently after resolve (state=${postState}, head=${expectedHead} -> ${postHead})`, EXIT_BLOCKED, {
        outcome: 'mutated_but_stale', mutated: true, reconciliation_required: true, thread_id: threadId, expected_head: expectedHead, remote_head: postHead, remote_state: postState
      });
    }

    recordAuditState(statePath, { action: 'resolve', status: 'PR_RESOLVE_OK', repo: repo.full, pr: prNumber, thread_id: threadId, fix_commit: fixCommit, head_sha: postHead });
    emit({
      status: 'PR_RESOLVE_OK',
      action: 'resolve',
      mutated: true,
      repo: repo.full,
      pr: prNumber,
      thread_id: threadId,
      fix_commit: fixCommit,
      is_resolved: true,
      verified_remote: true,
      verified_head: postHead
    }, EXIT_OK);
  });
}

// --- Subcommand 4: comment (R003, R004, R006, R009) ---
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
    const p = validateRelPath(String(item.path || ''), `Inline finding[${idx}].path`);
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
  const explicitKey = validateKey(flags['idempotency-key']);
  const maxPages = validateMaxPages(flags['max-pages']);
  const statePath = flags['state-file'] ? validateSafeFilePath(flags['state-file'], '--state-file', { mustExist: false, rejectTraversal: true }) : '';
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
    summaryBody = normalizeText(readSafeInputFile(flags['summary-file'], '--summary-file'));
    if (!summaryBody) {
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

  const canonicalPayload = JSON.stringify({ summary: summaryBody, inline: inlineComments });

  if (isDraft) {
    const draftIdentity = computeOperationIdentity({
      repo: repo.full, pr: prNumber, actor: 'draft', op: 'comment', targetKind: 'pr', targetId: String(prNumber), reviewedSha: expectedHead, mode, event, normalizedPayload: canonicalPayload, explicitKey
    });
    const finalPreview = appendMarker(summaryBody, draftIdentity.marker);
    if (finalPreview.length > MAX_BODY_CHARS) {
      fail('PR_FILE_GUARD', `Summary body exceeds ${MAX_BODY_CHARS} chars`, EXIT_ERROR);
    }
    emit({
      status: 'PR_DRAFT_OK',
      action: 'comment',
      mutated: false,
      repo: repo.full,
      pr: prNumber,
      expected_head: expectedHead,
      mode,
      event,
      idempotency_key: draftIdentity.key,
      operation_hash: draftIdentity.opHash,
      summary_preview: finalPreview,
      inline_count: inlineComments.length,
      inline_preview: inlineComments
    }, EXIT_OK);
  }

  if (!authWrite) {
    fail('PR_AUTH_REQUIRED', 'Explicit --authorize-write is required to publish PR comments (or use --draft)', EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
  }
  if (event !== 'COMMENT' && authReviewEvent !== event) {
    fail('PR_EVENT_UNAUTHORIZED', `Review event ${event} requires matching --authorize-review-event ${event}`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
  }

  return withStateLock(statePath, () => {
    assertNoPendingReconciliation(statePath, repo.full, prNumber);
    const header = fetchPrHeader(repo.owner, repo.name, prNumber);
    assertOpenAndFreshHead(header, expectedHead);

    // R006: validate changed files AND actual diff hunk anchors (line + side).
    if (inlineComments.length > 0) {
      const prFiles = fetchRestPaginated(`repos/${repo.full}/pulls/${prNumber}/files`, maxPages);
      const fileMap = new Map();
      for (const f of prFiles) {
        if (f?.filename) fileMap.set(String(f.filename), f);
      }
      for (const ic of inlineComments) {
        const fileObj = fileMap.get(ic.path);
        if (!fileObj) {
          fail('PR_TARGET_MISMATCH', `Inline path ${ic.path} is not in PR ${repo.full}#${prNumber} changed files`, EXIT_ERROR, { outcome: 'blocked_before_write', mutated: false });
        }
        const anchors = parseUnifiedDiffAnchors(fileObj.patch);
        if (!anchors) {
          fail('PR_DIFF_UNAVAILABLE', `Diff patch for ${ic.path} is unavailable or truncated; cannot validate inline anchor ${ic.path}:${ic.line} (${ic.side})`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
        }
        const validSet = ic.side === 'LEFT' ? anchors.leftLines : anchors.rightLines;
        if (!validSet.has(ic.line)) {
          fail('PR_INVALID_ANCHOR', `Inline anchor ${ic.path}:${ic.line} (${ic.side}) is not present in PR diff hunks`, EXIT_ERROR, { outcome: 'blocked_before_write', mutated: false });
        }
      }
    }

    const identity = computeOperationIdentity({
      repo: repo.full, pr: prNumber, actor: header.viewer, op: 'comment', targetKind: 'pr', targetId: String(prNumber), reviewedSha: expectedHead, mode, event, normalizedPayload: canonicalPayload, explicitKey
    });
    const finalBody = appendMarker(summaryBody, identity.marker);
    if (finalBody.length > MAX_BODY_CHARS) {
      fail('PR_FILE_GUARD', `Summary body exceeds ${MAX_BODY_CHARS} chars`, EXIT_ERROR);
    }

    // R003: scan both issue comments & PR reviews for actor-scoped idempotency & key collisions.
    const issueComments = fetchRestPaginated(`repos/${repo.full}/issues/${prNumber}/comments`, maxPages);
    const reviews = fetchRestPaginated(`repos/${repo.full}/pulls/${prNumber}/reviews`, maxPages);
    const combinedItems = [
      ...issueComments.map((c) => ({ id: c.id, author: c.user?.login || '', body: c.body || '' })),
      ...reviews.map((r) => ({ id: r.id, author: r.user?.login || '', body: r.body || '' }))
    ];
    const allowLegacy = mode === 'summary' && event === 'COMMENT' && inlineComments.length === 0;
    const idem = scanRemoteIdempotency(combinedItems, header.viewer, identity, summaryBody, allowLegacy);
    if (idem.status === 'COLLISION') {
      fail('PR_KEY_COLLISION', `Idempotency key ${identity.key} already used for a different comment/review on PR #${prNumber} (id ${idem.existingId})`, EXIT_BLOCKED, {
        outcome: 'blocked_before_write', mutated: false, existing_id: idem.existingId, key: identity.key
      });
    }
    if (idem.status === 'MATCH') {
      recordAuditState(statePath, { action: 'comment', status: 'PR_IDEMPOTENT_SKIP', repo: repo.full, pr: prNumber, mode, key: identity.key, op_hash: identity.opHash, existing_id: idem.existingId });
      emit({ status: 'PR_IDEMPOTENT_SKIP', action: 'comment', mutated: false, mode, key: identity.key, operation_hash: identity.opHash, existing_id: idem.existingId }, EXIT_OK);
    }

    // R004: immediate pre-write freshness recheck after all reads.
    recheckFreshBeforeMutation(repo.owner, repo.name, prNumber, expectedHead);
    recordAuditState(statePath, { action: 'comment', status: 'PENDING', repo: repo.full, pr: prNumber, mode, event, key: identity.key, op_hash: identity.opHash }, { critical: true });

    let created;
    let transport;
    if (mode === 'summary' && event === 'COMMENT') {
      transport = 'issue_comment';
      created = runPostWriteGuarded(statePath, { action: 'comment', repo: repo.full, pr: prNumber, extra: { mode, key: identity.key } }, () => ghRestPost(`repos/${repo.full}/issues/${prNumber}/comments`, { body: finalBody }));
    } else {
      transport = 'pull_review';
      const reviewPayload = { commit_id: expectedHead, event, body: finalBody };
      if (inlineComments.length > 0) {
        reviewPayload.comments = inlineComments;
      }
      created = runPostWriteGuarded(statePath, { action: 'comment', repo: repo.full, pr: prNumber, extra: { mode, key: identity.key } }, () => ghRestPost(`repos/${repo.full}/pulls/${prNumber}/reviews`, reviewPayload));
    }

    if (!created || !created.id) {
      recordAuditState(statePath, { action: 'comment', status: 'PR_POST_WRITE_UNVERIFIED', reconciliation_required: true, repo: repo.full, pr: prNumber, mode, key: identity.key }, { critical: false });
      fail('PR_POST_WRITE_UNVERIFIED', `Publishing PR comment (${transport}) did not return a created ID`, EXIT_ERROR, { outcome: 'mutated_unverified', mutated: true, reconciliation_required: true });
    }
    const createdId = String(created.id);

    // R009 + R004: re-fetch actual created comment/review object & verify actor, target, content, inline anchors, state & HEAD.
    const postHeader = runPostWriteGuarded(statePath, { action: 'comment', repo: repo.full, pr: prNumber, extra: { created_id: createdId, key: identity.key } }, () => fetchPrHeader(repo.owner, repo.name, prNumber));
    if (transport === 'issue_comment') {
      const vRes = runPostWriteGuarded(statePath, { action: 'comment', repo: repo.full, pr: prNumber, extra: { created_id: createdId, key: identity.key } }, () => ghRestGet(`repos/${repo.full}/issues/comments/${createdId}`, { allowNotFound: true }));
      const vObj = vRes.data;
      const authorOk = String(vObj?.user?.login || '').toLowerCase() === header.viewer.toLowerCase();
      const prOk = String(vObj?.issue_url || '').endsWith(`/issues/${prNumber}`);
      const bodyOk = String(vObj?.body || '').includes(identity.marker) && stripMarkers(vObj?.body || '') === stripMarkers(summaryBody);
      if (vRes.notFound || !vObj || String(vObj.id) !== createdId || !authorOk || !prOk || !bodyOk) {
        recordAuditState(statePath, { action: 'comment', status: 'PR_POST_WRITE_UNVERIFIED', reconciliation_required: true, repo: repo.full, pr: prNumber, created_id: createdId, key: identity.key }, { critical: false });
        fail('PR_POST_WRITE_UNVERIFIED', `Post-write verification failed for issue comment ${createdId} (authorOk=${authorOk}, prOk=${prOk}, bodyOk=${bodyOk})`, EXIT_ERROR, {
          outcome: 'mutated_unverified', mutated: true, reconciliation_required: true, created_id: createdId
        });
      }
    } else {
      const { vRes, revComments } = runPostWriteGuarded(statePath, { action: 'comment', repo: repo.full, pr: prNumber, extra: { created_id: createdId, key: identity.key } }, () => ({
        vRes: ghRestGet(`repos/${repo.full}/pulls/${prNumber}/reviews/${createdId}`, { allowNotFound: true }),
        revComments: inlineComments.length > 0 ? fetchRestPaginated(`repos/${repo.full}/pulls/${prNumber}/reviews/${createdId}/comments`, maxPages) : []
      }));
      const vRev = vRes.data;
      const authorOk = String(vRev?.user?.login || '').toLowerCase() === header.viewer.toLowerCase();
      const commitOk = String(vRev?.commit_id || '').toLowerCase() === expectedHead;
      const bodyOk = String(vRev?.body || '').includes(identity.marker) && stripMarkers(vRev?.body || '') === stripMarkers(summaryBody);
      const expectedStates = { COMMENT: 'COMMENTED', APPROVE: 'APPROVED', REQUEST_CHANGES: 'CHANGES_REQUESTED' };
      const revState = String(vRev?.state || '').toUpperCase();
      const stateOk = revState === expectedStates[event] || revState === event;
      let inlineOk = true;
      if (inlineComments.length > 0) {
        const returnedKeys = new Set(revComments.map((rc) => `${rc.path}:${rc.line || rc.original_line}:${String(rc.side || '').toUpperCase()}:${normalizeText(rc.body || '')}`));
        inlineOk = revComments.length === inlineComments.length && inlineComments.every((ic) => returnedKeys.has(`${ic.path}:${ic.line}:${ic.side}:${normalizeText(ic.body)}`));
      }
      if (vRes.notFound || !vRev || String(vRev.id) !== createdId || !authorOk || !commitOk || !bodyOk || !stateOk || !inlineOk) {
        recordAuditState(statePath, { action: 'comment', status: 'PR_POST_WRITE_UNVERIFIED', reconciliation_required: true, repo: repo.full, pr: prNumber, created_id: createdId, key: identity.key }, { critical: false });
        fail('PR_POST_WRITE_UNVERIFIED', `Post-write verification failed for pull review ${createdId} (authorOk=${authorOk}, commitOk=${commitOk}, bodyOk=${bodyOk}, stateOk=${stateOk}, inlineOk=${inlineOk})`, EXIT_ERROR, {
          outcome: 'mutated_unverified', mutated: true, reconciliation_required: true, created_id: createdId
        });
      }
    }

    if (postHeader.headSha !== expectedHead || postHeader.state !== 'OPEN') {
      recordAuditState(statePath, { action: 'comment', status: 'PR_POST_WRITE_HEAD_MOVED', reconciliation_required: true, repo: repo.full, pr: prNumber, created_id: createdId, expected_head: expectedHead, remote_head: postHeader.headSha, remote_state: postHeader.state }, { critical: false });
      fail('PR_POST_WRITE_HEAD_MOVED', `PR state/HEAD changed concurrently after publishing comment (state=${postHeader.state}, head=${expectedHead} -> ${postHeader.headSha})`, EXIT_BLOCKED, {
        outcome: 'mutated_but_stale', mutated: true, reconciliation_required: true, created_id: createdId, expected_head: expectedHead, remote_head: postHeader.headSha, remote_state: postHeader.state
      });
    }

    recordAuditState(statePath, { action: 'comment', status: 'PR_COMMENT_OK', repo: repo.full, pr: prNumber, mode, event, transport, key: identity.key, op_hash: identity.opHash, created_id: createdId, head_sha: postHeader.headSha });
    emit({
      status: 'PR_COMMENT_OK',
      action: 'comment',
      mutated: true,
      repo: repo.full,
      pr: prNumber,
      mode,
      event,
      transport,
      created_id: createdId,
      idempotency_key: identity.key,
      operation_hash: identity.opHash,
      inline_count: inlineComments.length,
      verified_remote: true,
      verified_head: postHeader.headSha
    }, EXIT_OK);
  });
}

// --- Top-level entry with safe full stdout drain (R002) ---
function main() {
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
      fail('PR_INVALID_ARGS', `Unknown subcommand: ${cmd}`, EXIT_ERROR);
  }
}

process.stdout.on('error', (err) => {
  if (err && err.code === 'EPIPE') {
    process.exitCode = process.exitCode || EXIT_ERROR;
  }
});

try {
  main();
} catch (err) {
  let payload;
  let code;
  if (err instanceof B3Exit) {
    payload = err.payload;
    code = err.code;
  } else {
    payload = { status: 'PR_API_ERROR', error: sanitizeUntrustedText(err?.message || String(err)).slice(0, 300) };
    code = EXIT_ERROR;
  }
  const serialized = JSON.stringify(payload) + '\n';
  process.exitCode = code;
  // Write full buffer and let Node drain stdout naturally before exiting (no process.exit truncation).
  process.stdout.write(serialized, 'utf8');
}
