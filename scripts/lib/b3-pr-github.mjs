#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { execGh, hasControlChars, resolveBashBinary } from './b3-gh-exec.mjs';

const EXIT_OK = 0;
const EXIT_ERROR = 1;
const EXIT_BLOCKED = 2;

const MAX_FILE_BYTES = 262144;
const MAX_BODY_CHARS = 65536;
const DEFAULT_MAX_PAGES = 20;
const MAX_ALLOWED_PAGES = 100;
const SCRIPT_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

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
const EVENT_TO_REVIEW_STATE = { COMMENT: 'COMMENTED', APPROVE: 'APPROVED', REQUEST_CHANGES: 'CHANGES_REQUESTED' };
const RESOLVED_STATUSES = new Set([
  'PR_REPLY_OK', 'PR_RESOLVE_OK', 'PR_COMMENT_OK', 'PR_IDEMPOTENT_SKIP',
  'PR_ALREADY_RESOLVED', 'RECONCILED_CONFIRMED', 'RECONCILED_ABSENT', 'RECONCILED_STALE'
]);

class B3Exit extends Error {
  constructor(payload, code) {
    super(payload.status || 'EXIT');
    this.payload = payload;
    this.code = code;
  }
}

const emit = (payload, code) => { throw new B3Exit(payload, code); };
const fail = (status, message, code = EXIT_ERROR, extra = {}) => emit({ status, error: message, ...extra }, code);
const sha256Hex = (str) => crypto.createHash('sha256').update(str, 'utf8').digest('hex');
const normalizeText = (str) => String(str || '').replace(/\r\n/g, '\n').trim();
const stripMarkers = (str) => normalizeText(String(str || '').replace(MARKER_SCAN_RE, ''));

function sanitizeUntrustedText(val) {
  return String(val ?? '')
    .replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g, '')
    .replace(/[\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]/g, '')
    .replace(/[\u{E0000}-\u{E007F}]/gu, '')
    .replace(/BEGIN_UNTRUSTED_PR_DATA/gi, 'BEGIN-UNTRUSTED-PR-DATA-ESCAPED')
    .replace(/END_UNTRUSTED_PR_DATA/gi, 'END-UNTRUSTED-PR-DATA-ESCAPED');
}
const frameUntrustedText = (val) => `${UNTRUSTED_START}\n${sanitizeUntrustedText(val)}\n${UNTRUSTED_END}`;

function parseArgs(argv) {
  if (!argv.length) fail('PR_INVALID_ARGS', 'Missing subcommand (expected: fetch, reply, resolve, comment, reconcile)');
  const cmd = argv[0];
  const booleanFlags = new Set(['include-resolved', 'include-bodies', 'authorize-write', 'authorize-resolve', 'draft']);
  const allowedByCmd = {
    fetch: new Set(['repo', 'pr', 'include-resolved', 'include-bodies', 'thread-id', 'max-pages']),
    reconcile: new Set(['repo', 'pr', 'repo-root', 'max-pages']),
    reply: new Set(['repo', 'pr', 'repo-root', 'expected-head', 'target-kind', 'target-id', 'body-file', 'idempotency-key', 'authorize-write', 'draft', 'max-pages']),
    resolve: new Set(['repo', 'pr', 'repo-root', 'expected-head', 'thread-id', 'fix-commit', 'evidence-file', 'authorize-resolve', 'draft', 'max-pages']),
    comment: new Set(['repo', 'pr', 'repo-root', 'expected-head', 'mode', 'event', 'summary-file', 'inline-json', 'idempotency-key', 'authorize-write', 'authorize-review-event', 'draft', 'max-pages'])
  };
  const allowed = allowedByCmd[cmd];
  if (!allowed) fail('PR_INVALID_ARGS', `Unknown subcommand: ${cmd} (expected: fetch, reply, resolve, comment, reconcile)`);
  const flags = {};
  for (let i = 1; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith('--')) fail('PR_INVALID_ARGS', `Unexpected positional argument: ${arg}`);
    const name = arg.slice(2);
    if (!name || !allowed.has(name)) fail('PR_INVALID_ARGS', `Flag --${name} is not allowed for subcommand ${cmd}`);
    if (booleanFlags.has(name)) {
      flags[name] = true;
    } else {
      if (i + 1 >= argv.length || argv[i + 1].startsWith('--')) fail('PR_INVALID_ARGS', `Missing value for --${name}`);
      flags[name] = argv[++i];
    }
  }
  return { cmd, flags };
}

function validateRepo(repo) {
  if (!repo || hasControlChars(repo) || !REPO_RE.test(repo) || repo.includes('..')) fail('PR_INVALID_ARGS', 'Invalid --repo (expected owner/repo)');
  const [owner, name] = repo.split('/');
  if (!owner || !name || owner === '.' || name === '.') fail('PR_INVALID_ARGS', 'Invalid --repo segments');
  return { owner, name, full: `${owner}/${name}` };
}

function validatePr(prStr) {
  if (!prStr || hasControlChars(prStr) || !PR_RE.test(prStr)) fail('PR_INVALID_ARGS', 'Invalid --pr (expected positive integer)');
  const num = Number.parseInt(prStr, 10);
  if (!Number.isSafeInteger(num) || num <= 0) fail('PR_INVALID_ARGS', 'Invalid --pr value');
  return num;
}

function validateSha(sha, flagName) {
  if (!sha || hasControlChars(sha) || !SHA_RE.test(sha)) fail('PR_INVALID_ARGS', `Invalid ${flagName} (expected 40-hex commit SHA)`);
  return sha.toLowerCase();
}

function validateId(id, flagName) {
  if (!id || hasControlChars(id) || !ID_RE.test(id)) fail('PR_INVALID_ARGS', `Invalid ${flagName}`);
  return id;
}

function validateKey(key) {
  if (key === undefined) return '';
  if (!key || hasControlChars(key) || !KEY_RE.test(key)) fail('PR_INVALID_ARGS', 'Invalid --idempotency-key (expected 4-80 chars of [A-Za-z0-9._:-])');
  return key;
}

function validateMaxPages(val) {
  if (val === undefined) return DEFAULT_MAX_PAGES;
  if (hasControlChars(val) || !PR_RE.test(val)) fail('PR_INVALID_ARGS', 'Invalid --max-pages');
  const num = Number.parseInt(val, 10);
  if (num < 1 || num > MAX_ALLOWED_PAGES) fail('PR_INVALID_ARGS', `--max-pages must be between 1 and ${MAX_ALLOWED_PAGES}`);
  return num;
}

function validateRelPath(p, label) {
  if (!p || hasControlChars(p) || p.startsWith('/') || p.includes('\\') || p.split('/').includes('..')) {
    fail('PR_INVALID_ARGS', `Invalid relative path in ${label}`);
  }
  return p;
}

// --- R007: Unified safe-path & symlink/reparse-point guard ---
function validateRawPathSyntax(filePath, flagName, rejectTraversal = true) {
  if (!filePath || hasControlChars(filePath) || filePath.includes('\0')) fail('PR_INVALID_ARGS', `Invalid ${flagName}`);
  if (/^[\\/]{2}/.test(filePath)) fail('PR_FILE_GUARD', `UNC/device namespace path rejected for ${flagName}`);
  if (/^[A-Za-z]:(?![\\/])/.test(filePath)) fail('PR_FILE_GUARD', `Drive-relative path rejected for ${flagName}`);
  const withoutDrive = filePath.replace(/^[A-Za-z]:/, '');
  if (withoutDrive.includes(':')) fail('PR_FILE_GUARD', `Unsafe path syntax rejected for ${flagName}`);
  const segments = withoutDrive.split(/[\\/]+/).filter(Boolean);
  if (rejectTraversal && segments.includes('..')) fail('PR_FILE_GUARD', `Path traversal rejected for ${flagName}`);
  for (const seg of segments) {
    const cleaned = seg.replace(/[\s.]+$/g, '').trim();
    const baseStem = seg.split('.')[0].trim();
    if (WIN_DEVICE_RE.test(cleaned) || WIN_DEVICE_RE.test(baseStem)) {
      fail('PR_FILE_GUARD', `Reserved device path rejected for ${flagName}`);
    }
  }
}

function assertAncestorsSafe(targetPath, flagName) {
  let cur = path.dirname(targetPath);
  const visited = new Set();
  while (cur && !visited.has(cur)) {
    visited.add(cur);
    if (process.platform === 'darwin' && (cur === '/var' || cur === '/tmp' || cur === '/etc')) break;
    let pst = null;
    try {
      pst = fs.lstatSync(cur);
    } catch (err) {
      if (!err || err.code !== 'ENOENT') fail('PR_FILE_GUARD', `Cannot inspect ancestor for ${flagName}: ${err?.code || 'ERR'}`);
    }
    if (pst) {
      if (pst.isSymbolicLink()) fail('PR_FILE_GUARD', `Symlink/reparse ancestor directory rejected for ${flagName}`);
      if (!pst.isDirectory()) fail('PR_FILE_GUARD', `Non-directory ancestor rejected for ${flagName}`);
    }
    const next = path.dirname(cur);
    if (next === cur) break;
    cur = next;
  }
}

function validateSafePath(targetPath, flagName, { expectDir = false, mustExist = true, maxBytes = MAX_FILE_BYTES } = {}) {
  validateRawPathSyntax(targetPath, flagName, true);
  const resolved = path.resolve(targetPath);
  let st = null;
  try {
    st = fs.lstatSync(resolved);
  } catch (err) {
    if (mustExist || !err || err.code !== 'ENOENT') fail('PR_FILE_GUARD', `Cannot access ${flagName}: ${err?.code || 'ERR'}`);
  }
  if (st) {
    if (st.isSymbolicLink()) fail('PR_FILE_GUARD', `Symlink/reparse point rejected for ${flagName}`);
    if (expectDir ? !st.isDirectory() : !st.isFile()) {
      fail('PR_FILE_GUARD', `${expectDir ? 'Directory' : 'Regular file'} required for ${flagName}`);
    }
    if (!expectDir && mustExist && st.size > maxBytes) fail('PR_FILE_GUARD', `${flagName} exceeds ${maxBytes} bytes`);
  }
  assertAncestorsSafe(resolved, flagName);
  return resolved;
}

function readSafeInputFile(filePath, flagName, maxBytes = MAX_FILE_BYTES) {
  const resolved = validateSafePath(filePath, flagName, { expectDir: false, mustExist: true, maxBytes });
  return fs.readFileSync(resolved, 'utf8').replace(/^\uFEFF/, '');
}

// --- R010 + R015: Shared <git-common-dir> PR state/lock + single-writer enforcement ---
const sameFsPath = (a, b) => (process.platform === 'win32' ? a.toLowerCase() === b.toLowerCase() : a === b);
const isB3CheckpointPath = (p) => /^\.b3\/(ship|research-ship|autodev)(\/|$)/.test(p);
const sortOrdinal = (arr) => [...arr].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));

function resolveGitContext(rawRepoRoot) {
  const base = rawRepoRoot
    ? validateSafePath(rawRepoRoot, '--repo-root', { expectDir: true, mustExist: true })
    : validateSafePath(process.cwd(), 'cwd', { expectDir: true, mustExist: true });
  const gitRes = spawnSync('git', ['-C', base, 'rev-parse', '--show-toplevel', '--git-dir', '--git-common-dir'], { encoding: 'utf8', shell: false, windowsHide: true });
  const lines = gitRes.error || gitRes.status !== 0 ? [] : String(gitRes.stdout || '').trim().split(/\r?\n/).map((s) => s.trim()).filter(Boolean);
  if (lines.length < 3) {
    fail('PR_FILE_GUARD', `Directory is not inside a Git working tree (${base}); canonical state requires a Git repository root`);
  }
  const repoRoot = validateSafePath(lines[0], 'git-toplevel', { expectDir: true, mustExist: true });
  const gitDir = validateSafePath(path.resolve(base, lines[1]), 'git-dir', { expectDir: true, mustExist: true });
  const gitCommonDir = validateSafePath(path.resolve(base, lines[2]), 'git-common-dir', { expectDir: true, mustExist: true });
  const realGitDir = fs.realpathSync(gitDir);
  const realCommonDir = fs.realpathSync(gitCommonDir);
  const isLinkedWorktree = !sameFsPath(realGitDir, realCommonDir);
  return { repoRoot, gitDir, gitCommonDir, realCommonDir, isLinkedWorktree };
}

function assertMutationOwnerAllowed(gitCtx, action, explicitRepoRoot) {
  const blocked = (reason, msg) => fail('PR_MUTATION_OWNER_REQUIRED', msg, EXIT_BLOCKED, {
    outcome: 'blocked_before_write', mutated: false, action, reason
  });
  const role = String(process.env.B3_PR_MUTATION_ROLE || '').trim().toLowerCase();
  const sub = String(process.env.B3_SUBAGENT || '').trim().toLowerCase();
  if (role === 'worker' || sub === '1' || sub === 'true') {
    blocked('worker_role_forbidden', `Worker/subagent context cannot execute external PR mutation (${action}); return proposed payload/evidence to parent orchestrator`);
  }
  if (gitCtx.isLinkedWorktree) {
    blocked('linked_worktree_forbidden', `Linked Git worktree (${gitCtx.repoRoot}) cannot execute external PR mutation (${action}); route mutations through the single-writer parent orchestrator`);
  }
  if (explicitRepoRoot) {
    const cwd = validateSafePath(process.cwd(), 'cwd', { expectDir: true, mustExist: true });
    const cwdRes = spawnSync('git', ['-C', cwd, 'rev-parse', '--git-dir', '--git-common-dir'], { encoding: 'utf8', shell: false, windowsHide: true });
    const cl = !cwdRes.error && cwdRes.status === 0 ? String(cwdRes.stdout || '').trim().split(/\r?\n/).map((s) => s.trim()).filter(Boolean) : [];
    if (cl.length >= 2) {
      let cwdGitDir = null;
      let cwdCommonDir = null;
      try {
        cwdGitDir = fs.realpathSync(path.resolve(cwd, cl[0]));
        cwdCommonDir = fs.realpathSync(path.resolve(cwd, cl[1]));
      } catch { /* ignore unresolvable cwd git paths */ }
      if (cwdGitDir && cwdCommonDir && !sameFsPath(cwdGitDir, cwdCommonDir) && sameFsPath(cwdCommonDir, gitCtx.realCommonDir)) {
        blocked('linked_worktree_cwd_bypass', `Process CWD is inside a linked worktree sharing ${gitCtx.gitCommonDir}; bypassing via --repo-root is forbidden for ${action}`);
      }
    }
  }
}

function resolveCanonicalStatePath(gitCommonDir, repoFull, prNumber) {
  const safeSlug = repoFull.toLowerCase().replace(/[^a-z0-9._-]/g, '__');
  const statePath = path.join(gitCommonDir, 'b3', 'pr-feedback', `${safeSlug}__pr-${prNumber}.state.json`);
  return validateSafePath(statePath, 'canonical-state', { expectDir: false, mustExist: false });
}

function readStateRecords(statePath) {
  if (!fs.existsSync(statePath)) return [];
  let raw;
  try {
    raw = fs.readFileSync(statePath, 'utf8').replace(/^\uFEFF/, '');
  } catch (err) {
    fail('PR_FILE_GUARD', `Cannot read canonical state file: ${err?.code || 'ERR'}`);
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    fail('PR_FILE_GUARD', 'Corrupt JSON in canonical state file; refusing to overwrite or bypass reconciliation');
  }
  if (!Array.isArray(parsed)) fail('PR_FILE_GUARD', 'Canonical state file must contain a JSON array');
  return parsed;
}

function appendStateRecord(statePath, entry, critical = false) {
  try {
    const dir = path.dirname(statePath);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    assertAncestorsSafe(statePath, 'canonical-state');
    const records = readStateRecords(statePath);
    records.push({ ...entry, recorded_at_utc: new Date().toISOString() });
    const tmpPath = `${statePath}.tmp.${process.pid}.${crypto.randomBytes(6).toString('hex')}`;
    fs.writeFileSync(tmpPath, JSON.stringify(records, null, 2) + '\n', { encoding: 'utf8', flag: 'wx', mode: 0o600 });
    fs.renameSync(tmpPath, statePath);
    return true;
  } catch (err) {
    if (err instanceof B3Exit) {
      if (critical) throw err;
      return false;
    }
    if (critical) fail('PR_FILE_GUARD', `Failed to persist critical state record: ${err?.code || err?.message || 'ERR'}`);
    return false;
  }
}

function getUnresolvedPendingRecords(records, repoFull, prNumber) {
  const byOp = new Map();
  for (const r of records) {
    if (String(r.repo || '').toLowerCase() !== repoFull.toLowerCase() || Number(r.pr) !== prNumber) continue;
    const opId = String(r.op_id || '__legacy__');
    if (r.status === 'PENDING' || r.reconciliation_required) {
      byOp.set(opId, r);
    } else if (RESOLVED_STATUSES.has(r.status)) {
      byOp.delete(opId);
    }
  }
  return [...byOp.values()];
}

function isPidAliveSameHost(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return 'UNKNOWN';
  try {
    process.kill(pid, 0);
    return 'ALIVE';
  } catch (err) {
    if (err && err.code === 'ESRCH') return 'DEAD';
    if (err && err.code === 'EPERM') return 'ALIVE';
    return 'UNKNOWN';
  }
}

function withStateLock(statePath, opName, fn) {
  const dir = path.dirname(statePath);
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
  assertAncestorsSafe(statePath, 'canonical-state');
  const lockPath = `${statePath}.lock`;
  const reclaimLockPath = `${lockPath}.reclaim`;
  const lockToken = crypto.randomBytes(16).toString('hex');
  const host = os.hostname();
  const lockBody = JSON.stringify({ pid: process.pid, host, token: lockToken, op: opName, started_at: Date.now() }) + '\n';

  const acquireOnce = () => {
    const fd = fs.openSync(lockPath, 'wx', 0o600);
    try { fs.writeSync(fd, lockBody); } finally { fs.closeSync(fd); }
  };

  try {
    acquireOnce();
  } catch (err) {
    if (!err || err.code !== 'EEXIST') fail('PR_FILE_GUARD', `Unable to create state lock: ${err?.code || 'ERR'}`);
    let st = null;
    try { st = fs.lstatSync(lockPath); } catch { st = null; }
    if (st && st.isSymbolicLink()) fail('PR_FILE_GUARD', `Symlink lock file rejected: ${lockPath}`);
    let existing = null;
    try { existing = JSON.parse(fs.readFileSync(lockPath, 'utf8')); } catch { existing = null; }
    // R012: NEVER reclaim by age alone; reclaim ONLY if same host AND PID confirmed dead (ESRCH).
    const sameHost = Boolean(existing && typeof existing.host === 'string' && existing.host === host);
    const liveness = sameHost ? isPidAliveSameHost(Number(existing.pid)) : 'UNKNOWN';
    if (liveness !== 'DEAD' || !existing?.token) {
      fail('PR_CONCURRENT_LOCK', `Active or unverified lock held on ${path.basename(statePath)} (host=${existing?.host || 'unknown'}, pid=${existing?.pid || 'unknown'}, state=${liveness})`, EXIT_BLOCKED, {
        outcome: 'blocked_before_write', mutated: false
      });
    }
    const reclaimToken = crypto.randomBytes(16).toString('hex');
    const reclaimBody = JSON.stringify({ pid: process.pid, host, token: reclaimToken, op: opName }) + '\n';
    try {
      const rfd = fs.openSync(reclaimLockPath, 'wx', 0o600);
      try { fs.writeSync(rfd, reclaimBody); } finally { fs.closeSync(rfd); }
    } catch (rErr) {
      let rst = null;
      try { rst = fs.lstatSync(reclaimLockPath); } catch { rst = null; }
      if (rst && rst.isSymbolicLink()) fail('PR_FILE_GUARD', `Symlink reclaim lock rejected: ${reclaimLockPath}`);
      if (rErr && rErr.code !== 'EEXIST') fail('PR_FILE_GUARD', `Unable to create reclaim mutex: ${rErr.code}`);
      fail('PR_CONCURRENT_LOCK', `Concurrent lock reclamation in progress for ${path.basename(statePath)}`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
    }
    try {
      let curSt = null;
      try { curSt = fs.lstatSync(lockPath); } catch { curSt = null; }
      if (curSt && curSt.isSymbolicLink()) fail('PR_FILE_GUARD', `Symlink lock file rejected: ${lockPath}`);
      let recheck = null;
      try { recheck = JSON.parse(fs.readFileSync(lockPath, 'utf8')); } catch { recheck = null; }
      const stillSameDead = Boolean(
        recheck && recheck.token === existing.token && recheck.host === host &&
        Number(recheck.pid) === Number(existing.pid) && isPidAliveSameHost(Number(recheck.pid)) === 'DEAD'
      );
      if (!stillSameDead) {
        fail('PR_CONCURRENT_LOCK', `Concurrent operation already reclaimed or replaced lock on ${path.basename(statePath)}`, EXIT_BLOCKED, {
          outcome: 'blocked_before_write', mutated: false
        });
      }
      const deadCopy = `${lockPath}.dead.${process.pid}.${lockToken.slice(0, 8)}`;
      try {
        fs.renameSync(lockPath, deadCopy);
        try { fs.unlinkSync(deadCopy); } catch { /* ignore */ }
        acquireOnce();
      } catch {
        fail('PR_CONCURRENT_LOCK', `Concurrent operation holds lock on ${path.basename(statePath)}`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
      }
    } finally {
      try {
        const recRaw = fs.readFileSync(reclaimLockPath, 'utf8');
        if (recRaw.includes(reclaimToken)) fs.unlinkSync(reclaimLockPath);
      } catch { /* ignore */ }
    }
  }
  try {
    return fn();
  } finally {
    try {
      const curRaw = fs.readFileSync(lockPath, 'utf8');
      if (curRaw.includes(lockToken)) fs.unlinkSync(lockPath);
    } catch { /* ignore */ }
  }
}

// --- Safe gh CLI transport (stdin-JSON only, via shared b3-gh-exec) ---
function invokeGh(args, stdinStr = null, options = {}) {
  for (const a of args) {
    if (!SAFE_GH_ARG_RE.test(a)) fail('PR_INVALID_ARGS', `Unsafe gh argument rejected: ${a}`);
  }
  const res = execGh(args, {
    stdin: stdinStr,
    maxBuffer: 64 * 1024 * 1024,
  });
  if (!res.ok) {
    if (res.reason === 'gh_not_found') fail('PR_API_ERROR', 'gh CLI not found in PATH');
    if (res.reason === 'unsafe_gh_path') fail('PR_API_ERROR', 'Unsafe path for gh CLI rejected');
    if (res.reason === 'unsafe_gh_arg') fail('PR_INVALID_ARGS', res.error?.message || 'Unsafe gh argument rejected');
    if (res.reason === 'timeout') fail('PR_API_ERROR', 'gh CLI timed out');
    fail('PR_API_ERROR', `Failed to invoke gh: ${res.error?.message || res.reason}`);
  }
  const stdout = (res.stdout || '').trim();
  const stderr = (res.stderr || '').trim();
  if (res.status !== 0) {
    if (options.allowNotFound && /404|Not Found/i.test(`${stderr}\n${stdout}`)) return { notFound: true, data: null };
    fail('PR_API_ERROR', `gh api failed (exit ${res.status}): ${sanitizeUntrustedText(stderr || stdout).slice(0, 300)}`);
  }
  if (!stdout) return { notFound: false, data: null };
  try {
    return { notFound: false, data: JSON.parse(stdout) };
  } catch {
    fail('PR_API_ERROR', 'gh api returned non-JSON output');
  }
}

function ghGraphQL(query, variables = {}) {
  const { data } = invokeGh(['api', 'graphql', '--input', '-'], JSON.stringify({ query, variables }));
  if (!data || typeof data !== 'object') fail('PR_API_ERROR', 'Empty GraphQL response');
  if (Array.isArray(data.errors) && data.errors.length) {
    fail('PR_API_ERROR', `GraphQL error: ${sanitizeUntrustedText(data.errors.map((e) => e.message || 'GraphQL error').join('; ')).slice(0, 300)}`);
  }
  if (!data.data) fail('PR_API_ERROR', 'Missing data in GraphQL response');
  return data.data;
}

const ghRestGet = (endpoint, options = {}) => invokeGh(['api', endpoint], null, options);
const ghRestPost = (endpoint, bodyObj) => invokeGh(['api', endpoint, '--method', 'POST', '--input', '-'], JSON.stringify(bodyObj)).data;

function fetchRestPaginated(endpointBase, maxPages) {
  const items = [];
  const sep = endpointBase.includes('?') ? '&' : '?';
  for (let page = 1; page <= maxPages; page += 1) {
    const { data } = ghRestGet(`${endpointBase}${sep}per_page=100&page=${page}`);
    if (!Array.isArray(data)) fail('PR_API_ERROR', `Expected array from ${endpointBase}`);
    items.push(...data);
    if (data.length < 100) return items;
  }
  fail('PR_PAGINATION_INCOMPLETE', `Pagination reached --max-pages (${maxPages}) on ${endpointBase}`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
}

// --- PR header, freshness & targeted retrieval (R004, R008) ---
function fetchPrHeader(owner, repo, prNumber) {
  const query = `query($owner: String!, $repo: String!, $pr: Int!) {
    viewer { login }
    repository(owner: $owner, name: $repo) { pullRequest(number: $pr) { number state headRefOid } }
  }`;
  const data = ghGraphQL(query, { owner, repo, pr: prNumber });
  const viewer = data.viewer?.login ? String(data.viewer.login) : '';
  const pr = data.repository?.pullRequest;
  if (!pr) fail('PR_TARGET_MISMATCH', `Pull request ${owner}/${repo}#${prNumber} not found`);
  if (!viewer) fail('PR_API_ERROR', 'Unable to resolve authenticated viewer.login');
  return { viewer, state: String(pr.state || ''), headSha: String(pr.headRefOid || '').toLowerCase() };
}

function assertOpenAndFreshHead(header, expectedHead) {
  if (header.state !== 'OPEN') {
    fail('PR_NOT_OPEN', `Pull request state is ${header.state}; expected OPEN`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false, state: header.state });
  }
  if (header.headSha !== expectedHead) {
    fail('PR_STALE_HEAD', `Remote PR HEAD (${header.headSha}) does not match expected (${expectedHead})`, EXIT_BLOCKED, {
      outcome: 'blocked_before_write', mutated: false, remote_head: header.headSha, expected_head: expectedHead
    });
  }
}

function paginateNestedThreadComments(threadId, initialConn, maxPages, includeBodies) {
  const fields = includeBodies ? 'id author { login } body' : 'id author { login }';
  const query = `query($threadId: ID!, $cursor: String) {
    node(id: $threadId) { ... on PullRequestReviewThread { comments(first: 100, after: $cursor) { pageInfo { hasNextPage endCursor } nodes { ${fields} } } } }
  }`;
  const comments = Array.isArray(initialConn?.nodes) ? [...initialConn.nodes] : [];
  let cInfo = initialConn?.pageInfo || { hasNextPage: false, endCursor: null };
  for (let p = 1; cInfo.hasNextPage; p += 1) {
    if (p >= maxPages) fail('PR_PAGINATION_INCOMPLETE', `Nested comment pagination reached --max-pages (${maxPages}) on thread ${threadId}`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
    const nConn = ghGraphQL(query, { threadId, cursor: cInfo.endCursor }).node?.comments;
    if (!nConn || !Array.isArray(nConn.nodes)) fail('PR_API_ERROR', `Unexpected nested comment response for thread ${threadId}`);
    comments.push(...nConn.nodes);
    cInfo = nConn.pageInfo || { hasNextPage: false, endCursor: null };
  }
  return comments;
}

function fetchSingleReviewThread(repoFull, prNumber, threadId, maxPages, includeComments) {
  const cBlock = includeComments
    ? 'comments(first: 100) { totalCount pageInfo { hasNextPage endCursor } nodes { id author { login } body } }'
    : 'comments(first: 1) { totalCount }';
  const query = `query($threadId: ID!) {
    node(id: $threadId) {
      ... on PullRequestReviewThread {
        id isResolved isOutdated path line originalLine
        pullRequest { number repository { nameWithOwner } }
        ${cBlock}
      }
    }
  }`;
  const node = ghGraphQL(query, { threadId }).node;
  if (!node || !node.id) return null;
  const ownerRepo = String(node.pullRequest?.repository?.nameWithOwner || '').toLowerCase();
  const nodePr = Number(node.pullRequest?.number || 0);
  if (!ownerRepo || ownerRepo !== repoFull.toLowerCase() || nodePr !== prNumber) {
    fail('PR_TARGET_MISMATCH', `Review thread ${threadId} belongs to ${ownerRepo || 'unknown'}#${nodePr}, not ${repoFull}#${prNumber}`);
  }
  const comments = includeComments ? paginateNestedThreadComments(threadId, node.comments, maxPages, true) : [];
  return {
    id: String(node.id),
    isResolved: Boolean(node.isResolved),
    isOutdated: Boolean(node.isOutdated),
    path: String(node.path || ''),
    line: node.line ?? node.originalLine ?? null,
    totalCount: node.comments?.totalCount ?? comments.length,
    comments: comments.map((c) => ({ id: String(c.id || ''), author: c.author?.login ? String(c.author.login) : 'unknown', body: String(c.body || '') }))
  };
}

function fetchAllReviewThreads(owner, repo, prNumber, maxPages, includeBodies) {
  const fields = includeBodies ? 'id author { login } body' : 'id author { login }';
  const query = `query($owner: String!, $repo: String!, $pr: Int!, $cursor: String) {
    viewer { login }
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $pr) {
        number state headRefOid title baseRefName headRefName ${includeBodies ? 'body' : ''}
        reviewThreads(first: 100, after: $cursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id isResolved isOutdated path line originalLine
            comments(first: 100) { totalCount pageInfo { hasNextPage endCursor } nodes { ${fields} } }
          }
        }
      }
    }
  }`;
  let cursor = null;
  let viewer = '';
  let prMeta = null;
  const threads = [];
  for (let page = 1; page <= maxPages; page += 1) {
    const data = ghGraphQL(query, { owner, repo, pr: prNumber, cursor });
    if (!viewer && data.viewer?.login) viewer = String(data.viewer.login);
    const pr = data.repository?.pullRequest;
    if (!pr) fail('PR_TARGET_MISMATCH', `Pull request ${owner}/${repo}#${prNumber} not found`);
    if (!prMeta) {
      prMeta = { number: pr.number, state: String(pr.state || ''), headSha: String(pr.headRefOid || '').toLowerCase(), title: pr.title || '', baseRefName: pr.baseRefName || '', headRefName: pr.headRefName || '', body: includeBodies ? (pr.body || '') : undefined };
    }
    const rt = pr.reviewThreads;
    for (const t of (Array.isArray(rt?.nodes) ? rt.nodes : [])) {
      if (!t?.id) continue;
      const cc = t.comments || {};
      const comments = includeBodies ? paginateNestedThreadComments(String(t.id), cc, maxPages, true) : (Array.isArray(cc.nodes) ? cc.nodes : []);
      threads.push({
        id: String(t.id), isResolved: Boolean(t.isResolved), isOutdated: Boolean(t.isOutdated),
        path: t.path || '', line: t.line ?? t.originalLine ?? null, totalCount: cc.totalCount ?? comments.length,
        hasMoreNestedComments: Boolean(cc.pageInfo?.hasNextPage) && !includeBodies,
        comments: comments.map((c) => ({ id: String(c.id || ''), author: c.author?.login ? String(c.author.login) : 'unknown', body: includeBodies ? String(c.body || '') : undefined }))
      });
    }
    if (!rt?.pageInfo?.hasNextPage) return { viewer, prMeta, threads };
    cursor = rt.pageInfo.endCursor;
  }
  fail('PR_PAGINATION_INCOMPLETE', `Review thread pagination reached --max-pages (${maxPages})`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
}

// --- R003 / R013: Operation identity & shared remote object verifier (reused by R009, R011, R013!) ---
function computeOperationIdentity(parts) {
  const canonical = JSON.stringify({
    repo: parts.repo.toLowerCase(), pr: parts.pr, actor: parts.actor.toLowerCase(), op: parts.op,
    target_kind: parts.targetKind || '', target_id: parts.targetId || '', reviewed_sha: parts.reviewedSha.toLowerCase(),
    mode: parts.mode || '', event: parts.event || '', payload_sha256: sha256Hex(normalizeText(parts.normalizedPayload))
  });
  const opHash = sha256Hex(canonical).slice(0, 16);
  const key = parts.explicitKey || `auto-${opHash}`;
  return { key, opHash, marker: `<!-- b3-pr-key:${key};op=${opHash} -->` };
}

function appendMarker(body, marker) {
  const cleaned = stripMarkers(body);
  return cleaned ? `${cleaned}\n\n${marker}` : marker;
}

function verifyInlineCommentsMatch(expectedInline, remoteComments) {
  if (!expectedInline || expectedInline.length === 0) return true;
  if (!Array.isArray(remoteComments) || remoteComments.length !== expectedInline.length) return false;
  const returnedKeys = new Set(remoteComments.map((rc) => `${rc.path}:${rc.line || rc.original_line}:${String(rc.side || '').toUpperCase()}:${normalizeText(rc.body || '')}`));
  return expectedInline.every((ic) => returnedKeys.has(`${ic.path}:${ic.line}:${ic.side}:${normalizeText(ic.body)}`));
}

function verifyRemoteObject(spec, maxPages) {
  const { kind, repo, pr, viewer, createdId, threadId, expectedHead, expectedBody, expectedBodySha256, marker, event, expectedInline } = spec;
  const actorLower = String(viewer || '').toLowerCase();
  const bodyMatches = (remoteBody) => {
    const str = String(remoteBody || '');
    if (marker && !str.includes(marker)) return false;
    const stripped = stripMarkers(str);
    if (expectedBody !== undefined && stripped !== stripMarkers(expectedBody)) return false;
    if (expectedBodySha256 && sha256Hex(stripped) !== expectedBodySha256) return false;
    return true;
  };
  const [owner, name] = repo.split('/');

  if (kind === 'review_thread_reply') {
    const q = `query($owner: String!, $repo: String!, $pr: Int!, $threadId: ID!, $commentId: ID!) {
      repository(owner: $owner, name: $repo) { pullRequest(number: $pr) { state headRefOid } }
      thread: node(id: $threadId) { ... on PullRequestReviewThread { id isResolved pullRequest { number repository { nameWithOwner } } } }
      comment: node(id: $commentId) { ... on PullRequestReviewComment { id author { login } body pullRequest { number } } }
    }`;
    const d = ghGraphQL(q, { owner, repo: name, pr, threadId, commentId: createdId });
    const postState = String(d.repository?.pullRequest?.state || '');
    const postHead = String(d.repository?.pullRequest?.headRefOid || '').toLowerCase();
    const c = d.comment;
    const t = d.thread;
    if (!c) return { found: false, ok: false, postState, postHead, reason: 'comment_not_found' };
    const tOwner = String(t?.pullRequest?.repository?.nameWithOwner || '').toLowerCase();
    const ok = String(c.id) === String(createdId) &&
      String(c.author?.login || '').toLowerCase() === actorLower &&
      Number(c.pullRequest?.number) === pr &&
      Boolean(t && String(t.id) === threadId && (!tOwner || tOwner === repo.toLowerCase())) &&
      bodyMatches(c.body);
    return { found: true, ok, postState, postHead, reason: ok ? 'verified' : 'content_or_target_mismatch' };
  }

  if (kind === 'issue_comment') {
    const vRes = ghRestGet(`repos/${repo}/issues/comments/${createdId}`, { allowNotFound: true });
    const postHeader = fetchPrHeader(owner, name, pr);
    const c = vRes.data;
    if (vRes.notFound || !c) return { found: false, ok: false, postState: postHeader.state, postHead: postHeader.headSha, reason: 'comment_not_found' };
    const ok = String(c.id) === String(createdId) &&
      String(c.user?.login || '').toLowerCase() === actorLower &&
      String(c.issue_url || '').endsWith(`/issues/${pr}`) &&
      bodyMatches(c.body);
    return { found: true, ok, postState: postHeader.state, postHead: postHeader.headSha, reason: ok ? 'verified' : 'content_or_target_mismatch' };
  }

  if (kind === 'pull_review') {
    const vRes = ghRestGet(`repos/${repo}/pulls/${pr}/reviews/${createdId}`, { allowNotFound: true });
    const postHeader = fetchPrHeader(owner, name, pr);
    const r = vRes.data;
    if (vRes.notFound || !r) return { found: false, ok: false, postState: postHeader.state, postHead: postHeader.headSha, reason: 'review_not_found' };
    const revState = String(r.state || '').toUpperCase();
    const stateOk = revState !== 'DISMISSED' && (revState === EVENT_TO_REVIEW_STATE[event] || revState === event);
    const commitOk = String(r.commit_id || '').toLowerCase() === String(expectedHead || '').toLowerCase();
    const revComments = (expectedInline && expectedInline.length > 0)
      ? fetchRestPaginated(`repos/${repo}/pulls/${pr}/reviews/${createdId}/comments`, maxPages)
      : [];
    const inlineOk = verifyInlineCommentsMatch(expectedInline, revComments);
    const ok = String(r.id) === String(createdId) &&
      String(r.user?.login || '').toLowerCase() === actorLower &&
      stateOk && commitOk && bodyMatches(r.body) && inlineOk;
    return { found: true, ok, postState: postHeader.state, postHead: postHeader.headSha, reason: ok ? 'verified' : `review_mismatch(state=${revState},commitOk=${commitOk},inlineOk=${inlineOk})` };
  }

  if (kind === 'resolve_thread') {
    const q = `query($owner: String!, $repo: String!, $pr: Int!, $threadId: ID!) {
      repository(owner: $owner, name: $repo) { pullRequest(number: $pr) { state headRefOid } }
      node(id: $threadId) { ... on PullRequestReviewThread { id isResolved pullRequest { number repository { nameWithOwner } } } }
    }`;
    const d = ghGraphQL(q, { owner, repo: name, pr, threadId });
    const postState = String(d.repository?.pullRequest?.state || '');
    const postHead = String(d.repository?.pullRequest?.headRefOid || '').toLowerCase();
    const t = d.node;
    if (!t) return { found: false, ok: false, postState, postHead, reason: 'thread_not_found' };
    const tOwner = String(t.pullRequest?.repository?.nameWithOwner || '').toLowerCase();
    const ok = String(t.id) === threadId && Boolean(t.isResolved) && tOwner === repo.toLowerCase() && Number(t.pullRequest?.number) === pr;
    return { found: true, ok, isResolved: Boolean(t.isResolved), postState, postHead, reason: ok ? 'verified' : 'thread_not_resolved_or_mismatch' };
  }

  fail('PR_API_ERROR', `Unknown verification kind: ${kind}`);
}

function checkIdempotencyWithRevalidation(items, viewerLogin, identity, revalidateCandidate) {
  const actorLower = viewerLogin.toLowerCase();
  for (const item of items) {
    if (String(item.author || '').toLowerCase() !== actorLower) continue;
    const body = String(item.body || '');
    MARKER_SCAN_RE.lastIndex = 0;
    let m;
    while ((m = MARKER_SCAN_RE.exec(body)) !== null) {
      const foundKey = m[1];
      const foundOp = m[2] || '';
      const keyMatch = foundKey === identity.key;
      const opMatch = Boolean(foundOp && foundOp === identity.opHash);
      if (keyMatch && (!foundOp || !opMatch)) {
        return { status: 'COLLISION', existingId: String(item.id), reason: !foundOp ? 'legacy_marker_missing_op_hash' : 'op_hash_mismatch' };
      }
      if (keyMatch || opMatch) {
        const check = revalidateCandidate(item, identity.marker);
        if (check.ok) return { status: 'MATCH', existingId: String(item.id) };
        return { status: 'REMOTE_MISMATCH', existingId: String(item.id), reason: check.reason || 'remote_object_modified' };
      }
    }
  }
  return { status: 'NONE' };
}

// --- R014: Strict unified diff hunk validator ---
function parseUnifiedDiffAnchors(patch) {
  if (typeof patch !== 'string' || !patch.trim()) return { ok: false, reason: 'missing_or_empty_patch' };
  const rightLines = new Set();
  const leftLines = new Set();
  const lines = patch.split(/\r?\n/);
  if (lines.length > 0 && lines[lines.length - 1] === '') lines.pop();

  let sawHunk = false;
  let inHunk = false;
  let leftLine = 0;
  let rightLine = 0;
  let expLeft = 0;
  let expRight = 0;
  let seenLeft = 0;
  let seenRight = 0;
  const hunkBalanced = () => !inHunk || (seenLeft === expLeft && seenRight === expRight);

  for (const rawLine of lines) {
    const hunk = rawLine.match(/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/);
    if (hunk) {
      if (!hunkBalanced()) return { ok: false, reason: 'truncated_or_count_mismatch' };
      sawHunk = true;
      inHunk = true;
      leftLine = Number.parseInt(hunk[1], 10);
      expLeft = hunk[2] !== undefined ? Number.parseInt(hunk[2], 10) : 1;
      rightLine = Number.parseInt(hunk[3], 10);
      expRight = hunk[4] !== undefined ? Number.parseInt(hunk[4], 10) : 1;
      seenLeft = 0;
      seenRight = 0;
      continue;
    }
    if (!inHunk) {
      if (/^(diff --git |index |--- |\+\+\+ |new file|deleted file|old mode|new mode|rename |similarity )/.test(rawLine)) continue;
      return { ok: false, reason: 'malformed_diff_preamble' };
    }
    if (rawLine.startsWith('+')) {
      rightLines.add(rightLine++);
      seenRight += 1;
    } else if (rawLine.startsWith('-')) {
      leftLines.add(leftLine++);
      seenLeft += 1;
    } else if (rawLine.startsWith(' ')) {
      leftLines.add(leftLine++);
      rightLines.add(rightLine++);
      seenLeft += 1;
      seenRight += 1;
    } else if (rawLine.startsWith('\\ No newline at end of file')) {
      continue;
    } else {
      return { ok: false, reason: 'malformed_hunk_line' };
    }
    if (seenLeft > expLeft || seenRight > expRight) return { ok: false, reason: 'hunk_line_count_overflow' };
  }
  if (!sawHunk || !hunkBalanced()) return { ok: false, reason: 'truncated_or_count_mismatch' };
  return { ok: true, rightLines, leftLines };
}

// --- R001 + R016: Canonical B3 verify-check + exact remote committed-tree verification ---
function assertCleanIndexAndWorkingTree(repoRoot) {
  const stRes = spawnSync('git', ['-C', repoRoot, '-c', 'core.quotepath=false', 'status', '--porcelain=v1', '-z', '--untracked-files=all'], { encoding: 'utf8', shell: false, windowsHide: true });
  if (stRes.error || stRes.status !== 0) {
    fail('PR_VERIFY_REQUIRED', `Unable to inspect working tree cleanliness in ${repoRoot} for exact-commit verification`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
  }
  const dirty = [];
  const tokens = String(stRes.stdout || '').split('\0');
  for (let i = 0; i < tokens.length; i += 1) {
    const entry = tokens[i];
    if (!entry) continue;
    if (entry.length < 4) fail('PR_VERIFY_REQUIRED', 'Malformed git status output during exact-commit verification', EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
    const xy = entry.slice(0, 2);
    const rel = entry.slice(3).replace(/\\/g, '/').replace(/^(\.\/)+/, '');
    const orig = (xy.includes('R') || xy.includes('C')) ? String(tokens[++i] || '').replace(/\\/g, '/').replace(/^(\.\/)+/, '') : '';
    if (rel && !isB3CheckpointPath(rel)) dirty.push(rel);
    else if (orig && !isB3CheckpointPath(orig)) dirty.push(orig);
  }
  if (dirty.length > 0) {
    const preview = dirty.slice(0, 5).map(sanitizeUntrustedText).join(', ') + (dirty.length > 5 ? ` (+${dirty.length - 5} more)` : '');
    fail('PR_VERIFY_REQUIRED', `Uncommitted or untracked working-tree/index changes absent from PR HEAD (${preview})`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false, dirty_paths: dirty.slice(0, 20) });
  }
}

function computeCommittedTreeHash(repoRoot, expectedHead, receiptRelPathsRaw) {
  const normRel = (p) => String(p || '').trim().replace(/\\/g, '/').replace(/^(\.\/)+/, '').replace(/\/+$/, '');
  let cleanRel = [];
  if (receiptRelPathsRaw && receiptRelPathsRaw !== 'ALL') {
    const set = new Set();
    for (const part of String(receiptRelPathsRaw).split(',')) {
      const np = normRel(part);
      if (np && np !== 'none' && !isB3CheckpointPath(np)) set.add(np);
    }
    cleanRel = sortOrdinal(set);
    if (cleanRel.length === 0) fail('PR_VERIFY_REQUIRED', 'Receipt relevant_paths resolved empty during exact-commit check', EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
  }
  const pathsCsv = cleanRel.length > 0 ? cleanRel.join(',') : 'ALL';
  const lsArgs = ['-C', repoRoot, '-c', 'core.quotepath=false', 'ls-tree', '-r', '-z', expectedHead, ...(cleanRel.length > 0 ? ['--', ...cleanRel] : [])];
  const lsRes = spawnSync('git', lsArgs, { encoding: 'utf8', shell: false, windowsHide: true });
  if (lsRes.error || lsRes.status !== 0) {
    fail('PR_VERIFY_REQUIRED', `Unable to read committed tree for ${expectedHead} in ${repoRoot}`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
  }
  const effective = new Map();
  for (const rec of String(lsRes.stdout || '').split('\0')) {
    if (!rec) continue;
    const tabIdx = rec.indexOf('\t');
    if (tabIdx < 1) continue;
    const meta = rec.slice(0, tabIdx).trim().split(/\s+/);
    if (meta.length < 3 || !/^[0-9]{6}$/.test(meta[0]) || (meta[1] !== 'blob' && meta[1] !== 'commit') || !/^[0-9a-f]{40}$/.test(meta[2])) continue;
    const p = normRel(rec.slice(tabIdx + 1));
    if (!p || isB3CheckpointPath(p)) continue;
    if (cleanRel.length > 0 && !cleanRel.some((r) => r === '.' || p === r || p.startsWith(`${r}/`))) continue;
    effective.set(p, `${meta[0]} ${meta[1]} ${meta[2]}`);
  }
  const manifestLines = [`PATHS=${pathsCsv}`];
  for (const ep of sortOrdinal(effective.keys())) manifestLines.push(`E ${effective.get(ep)} ${ep}`);
  const hashRes = spawnSync('git', ['-C', repoRoot, 'hash-object', '--stdin'], { input: manifestLines.join('\n') + '\n', encoding: 'utf8', shell: false, windowsHide: true });
  const hash = String(hashRes.stdout || '').trim().toLowerCase();
  if (hashRes.error || hashRes.status !== 0 || !SHA_RE.test(hash)) {
    fail('PR_VERIFY_REQUIRED', 'Unable to hash committed tree manifest for exact-commit verification', EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
  }
  return hash;
}

function isRunnableBinary(filePath) {
  if (!filePath || hasControlChars(filePath)) return false;
  if (process.platform === 'win32' && /\\microsoft\\windowsapps\\/i.test(filePath.replace(/\//g, '\\'))) return false;
  try {
    const st = fs.statSync(filePath);
    if (!st.isFile()) return false;
    if (process.platform !== 'win32') fs.accessSync(filePath, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

let cachedPsKey = null;
let cachedPsPath = '';
function resolvePowerShellBinary() {
  const pathEnv = process.env.PATH || process.env.Path || '';
  if (cachedPsKey === pathEnv) return cachedPsPath;
  const finish = (val) => { cachedPsKey = pathEnv; cachedPsPath = val; return val; };
  const isWin = process.platform === 'win32';
  const dirs = pathEnv.split(path.delimiter).filter(Boolean);

  const pwshNames = isWin ? ['pwsh.exe'] : ['pwsh'];
  for (const d of dirs) {
    for (const name of pwshNames) {
      const cand = path.join(d, name);
      if (isRunnableBinary(cand)) return finish(cand);
    }
  }
  if (isWin) {
    const pwsh7 = path.join(process.env.ProgramFiles || 'C:\\Program Files', 'PowerShell', '7', 'pwsh.exe');
    if (isRunnableBinary(pwsh7)) return finish(pwsh7);
  }

  const psNames = isWin ? ['powershell.exe'] : ['powershell'];
  for (const d of dirs) {
    for (const name of psNames) {
      const cand = path.join(d, name);
      if (isRunnableBinary(cand)) return finish(cand);
    }
  }
  if (isWin) {
    const winPs = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
    if (isRunnableBinary(winPs)) return finish(winPs);
  }
  return finish('');
}

function runCanonicalVerifyCheck(repoRoot, receiptFullPath, expectedHead, expectedCmd, requiredPaths) {
  const headRes = spawnSync('git', ['-C', repoRoot, 'rev-parse', '--verify', `${expectedHead}^{commit}`], { encoding: 'utf8', shell: false, windowsHide: true });
  const localHeadRes = spawnSync('git', ['-C', repoRoot, 'rev-parse', '--verify', 'HEAD^{commit}'], { encoding: 'utf8', shell: false, windowsHide: true });
  if (headRes.error || headRes.status !== 0 || localHeadRes.error || localHeadRes.status !== 0) {
    fail('PR_VERIFY_REQUIRED', `Unable to verify local Git HEAD or remote commit ${expectedHead} in ${repoRoot}`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
  }
  const localHead = localHeadRes.stdout.trim().toLowerCase();
  if (localHead !== expectedHead) {
    fail('PR_VERIFY_REQUIRED', `Local repository HEAD (${localHead}) does not match expected remote PR HEAD (${expectedHead})`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
  }

  const realRoot = fs.realpathSync(repoRoot);
  const realReceipt = fs.realpathSync(receiptFullPath);
  const relReceipt = path.relative(realRoot, realReceipt).replace(/\\/g, '/');
  if (!relReceipt || relReceipt === '.' || relReceipt.startsWith('..') || path.isAbsolute(relReceipt) || relReceipt.includes(':') || !relReceipt.startsWith('.b3/')) {
    fail('PR_VERIFY_REQUIRED', `Verification receipt must reside inside repository .b3/ directory (${repoRoot})`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
  }

  const reqCsv = requiredPaths.join(',');
  let guardRes;
  const bashBin = resolveBashBinary();
  if (bashBin) {
    const guardSh = process.platform === 'win32'
      ? path.join(SCRIPT_ROOT, 'b3-guard.sh').replace(/\\/g, '/')
      : path.join(SCRIPT_ROOT, 'b3-guard.sh');
    const rootArg = process.platform === 'win32' ? repoRoot.replace(/\\/g, '/') : repoRoot;
    guardRes = spawnSync(bashBin, [guardSh, 'verify-check', '--repo-root', rootArg, '--receipt-path', relReceipt, '--expected-cmd', expectedCmd, '--relevant-paths', reqCsv], { encoding: 'utf8', shell: false, windowsHide: true });
  } else {
    const psBin = resolvePowerShellBinary();
    if (!psBin) {
      fail('PR_VERIFY_REQUIRED', 'Neither bash nor PowerShell (pwsh/powershell) found to run b3-guard verify-check', EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
    }
    const psCmd = '& $env:B3_VC_GUARD verify-check -RepoRoot ([string]$env:B3_VC_ROOT) -ReceiptPath ([string]$env:B3_VC_RECEIPT) -ExpectedCmd ([string]$env:B3_VC_CMD) -RelevantPaths ([string]$env:B3_VC_PATHS); exit $LASTEXITCODE';
    const psArgs = process.platform === 'win32'
      ? ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', psCmd]
      : ['-NoProfile', '-Command', psCmd];
    const vcEnv = {
      ...process.env,
      B3_VC_GUARD: path.join(SCRIPT_ROOT, 'b3-guard.ps1'),
      B3_VC_ROOT: repoRoot,
      B3_VC_RECEIPT: relReceipt,
      B3_VC_HEAD: expectedHead,
      B3_VC_CMD: expectedCmd,
      B3_VC_PATHS: reqCsv,
    };
    guardRes = spawnSync(psBin, psArgs, { encoding: 'utf8', env: vcEnv, shell: false, windowsHide: true });
  }
  const guardOut = `${guardRes.stdout || ''}\n${guardRes.stderr || ''}`.trim();
  if (guardRes.error || guardRes.status !== 0 || !guardOut.includes('VERIFY_VALID:')) {
    fail('PR_VERIFY_REQUIRED', `Canonical b3-guard verify-check failed (exit ${guardRes.status ?? 'err'}): ${sanitizeUntrustedText(guardOut).slice(0, 260)}`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
  }

  const receiptText = readSafeInputFile(receiptFullPath, 'verify_receipt_path');
  const kv = {};
  for (const line of receiptText.split(/\r?\n/)) {
    const eq = line.indexOf('=');
    if (eq > 0) kv[line.slice(0, eq).trim()] = line.slice(eq + 1).trim();
  }
  const recHead = String(kv.head_sha || '').toLowerCase();
  if (recHead !== expectedHead) {
    fail('PR_VERIFY_REQUIRED', `Receipt head_sha (${recHead || 'missing'}) does not match exact PR HEAD (${expectedHead})`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
  }
  assertCleanIndexAndWorkingTree(repoRoot);
  const committedTreeHash = computeCommittedTreeHash(repoRoot, expectedHead, kv.relevant_paths || 'ALL');
  if (committedTreeHash !== String(kv.tree_hash || '').toLowerCase()) {
    fail('PR_VERIFY_REQUIRED', `Receipt tree_hash (${kv.tree_hash || 'missing'}) does not match exact committed tree (${committedTreeHash}) at ${expectedHead}`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
  }
  return { guardMessage: guardOut.split(/\r?\n/)[0], committedTreeHash };
}

function parseResolveEvidence(evidencePath, repoRoot, repoFull, prNumber, expectedHead, threadId, fixCommit) {
  const raw = readSafeInputFile(evidencePath, '--evidence-file');
  let ev;
  try { ev = JSON.parse(raw); } catch { fail('PR_VERIFY_REQUIRED', '--evidence-file is not valid JSON', EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false }); }
  const blocked = (msg) => fail('PR_VERIFY_REQUIRED', msg, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
  if (!ev || typeof ev !== 'object' || ev.schema !== 'b3-pr-verify-evidence-v1') blocked('Evidence schema must be b3-pr-verify-evidence-v1');
  if (String(ev.repo || '').toLowerCase() !== repoFull.toLowerCase()) blocked(`Evidence repo (${ev.repo}) does not match ${repoFull}`);
  if (Number(ev.pr) !== prNumber) blocked(`Evidence PR (${ev.pr}) does not match #${prNumber}`);
  if (String(ev.head_sha || '').toLowerCase() !== expectedHead) blocked(`Evidence head_sha (${ev.head_sha}) does not match expected HEAD (${expectedHead})`);
  if (String(ev.thread_id || '') !== threadId) blocked(`Evidence thread_id (${ev.thread_id}) does not match ${threadId}`);
  if (String(ev.fix_commit || '').toLowerCase() !== fixCommit) blocked(`Evidence fix_commit (${ev.fix_commit}) does not match ${fixCommit}`);
  const basis = String(ev.resolution_basis || '');
  if (!ALLOWED_BASES.has(basis)) blocked(`Invalid evidence resolution_basis (${basis})`);
  const primaryThreadId = basis === 'DUPLICATE_FIXED' ? String(ev.primary_thread_id || '') : '';
  if (basis === 'DUPLICATE_FIXED' && (!ID_RE.test(primaryThreadId) || primaryThreadId === threadId)) blocked('DUPLICATE_FIXED requires a distinct valid primary_thread_id');
  const targetPath = validateRelPath(String(ev.target_path || '').trim(), 'evidence.target_path');
  const fixedPaths = Array.isArray(ev.fixed_paths) ? ev.fixed_paths.map((p, i) => validateRelPath(String(p || '').trim(), `evidence.fixed_paths[${i}]`)) : [];
  const checkedCommand = String(ev.checked_command || '').trim();
  const summary = String(ev.summary || '').trim();
  if (!checkedCommand || summary.length < 10) blocked('Evidence requires non-empty checked_command and descriptive summary (>=10 chars)');
  const receiptRel = String(ev.verify_receipt_path || '').trim();
  if (!receiptRel) blocked('Evidence requires verify_receipt_path');
  validateRawPathSyntax(receiptRel, 'verify_receipt_path', true);
  const receiptCandidate = path.isAbsolute(receiptRel) ? path.resolve(receiptRel) : path.resolve(repoRoot, receiptRel);
  const receiptFullPath = validateSafePath(receiptCandidate, 'verify_receipt_path', { expectDir: false, mustExist: true });
  const dotB3Dir = path.join(repoRoot, '.b3');
  let dotB3Ok = false;
  try {
    const lst = fs.lstatSync(dotB3Dir);
    dotB3Ok = !lst.isSymbolicLink() && lst.isDirectory() && fs.statSync(dotB3Dir).isDirectory();
  } catch {
    dotB3Ok = false;
  }
  if (!dotB3Ok) {
    blocked(`Verification receipt must reside inside repository .b3/ directory (${dotB3Dir})`);
  }
  const relCheck = path.relative(fs.realpathSync(dotB3Dir), fs.realpathSync(receiptFullPath)).replace(/\\/g, '/');
  if (!relCheck || relCheck === '.' || relCheck.startsWith('..') || path.isAbsolute(relCheck) || relCheck.includes(':')) {
    blocked(`Verification receipt must reside inside repository .b3/ directory (${dotB3Dir})`);
  }
  return { basis, primaryThreadId, targetPath, fixedPaths, checkedCommand, receiptFullPath };
}

// --- Unified guarded mutation lifecycle ---
function executeGuardedMutation({ statePath, repo, prNumber, expectedHead, action, maxPages, prepare, beforeMutate, mutate, verifySpec, onSuccessPayload }) {
  return withStateLock(statePath, action, () => {
    const pending = getUnresolvedPendingRecords(readStateRecords(statePath), repo.full, prNumber);
    if (pending.length > 0) {
      fail('PR_RECONCILIATION_REQUIRED', `Unresolved prior operation(s) (${pending.map((p) => p.status).join(', ')}) on ${repo.full}#${prNumber} require reconciliation via reconcile subcommand`, EXIT_BLOCKED, {
        outcome: 'blocked_before_write', mutated: false, pending_records: pending
      });
    }
    const header = fetchPrHeader(repo.owner, repo.name, prNumber);
    assertOpenAndFreshHead(header, expectedHead);

    const prep = prepare(header);
    if (prep.earlyEmit) {
      if (prep.auditRecord) appendStateRecord(statePath, prep.auditRecord);
      emit(prep.earlyEmit, EXIT_OK);
    }

    assertOpenAndFreshHead(fetchPrHeader(repo.owner, repo.name, prNumber), expectedHead);
    if (beforeMutate) beforeMutate();

    const opId = `${action}-${crypto.randomBytes(8).toString('hex')}`;
    const pendingRecord = {
      op_id: opId, action, status: 'PENDING', repo: repo.full, pr: prNumber, actor: header.viewer,
      reviewed_sha: expectedHead, ...prep.pendingMeta
    };
    appendStateRecord(statePath, pendingRecord, true);

    let createdId = null;
    const guardPostWrite = (fn) => {
      try {
        return fn();
      } catch (err) {
        if (err instanceof B3Exit && ['PR_POST_WRITE_UNVERIFIED', 'PR_POST_WRITE_HEAD_MOVED'].includes(err.payload?.status)) throw err;
        const reason = err instanceof B3Exit ? `${err.payload?.status}: ${err.payload?.error}` : sanitizeUntrustedText(err?.message || String(err)).slice(0, 240);
        appendStateRecord(statePath, { ...pendingRecord, status: 'PR_POST_WRITE_UNVERIFIED', reconciliation_required: true, created_id: createdId, detail: reason });
        fail('PR_POST_WRITE_UNVERIFIED', `Post-write step interrupted (${reason}); run reconcile before retrying`, EXIT_ERROR, {
          outcome: 'mutated_unverified', mutated: true, reconciliation_required: true, op_id: opId, ...(createdId ? { created_id: createdId } : {}), ...(prep.extraIds || {})
        });
      }
    };

    const mutResult = guardPostWrite(() => mutate(prep, header));
    createdId = mutResult?.createdId ? String(mutResult.createdId) : null;
    if (mutResult?.requireId && !createdId) {
      appendStateRecord(statePath, { ...pendingRecord, status: 'PR_POST_WRITE_UNVERIFIED', reconciliation_required: true, detail: 'missing_created_id' });
      fail('PR_POST_WRITE_UNVERIFIED', `${action} did not return a created object ID`, EXIT_ERROR, {
        outcome: 'mutated_unverified', mutated: true, reconciliation_required: true, op_id: opId, ...(prep.extraIds || {})
      });
    }

    const vRes = guardPostWrite(() => verifyRemoteObject(verifySpec(prep, header, createdId), maxPages));
    if (!vRes.ok) {
      appendStateRecord(statePath, { ...pendingRecord, status: 'PR_POST_WRITE_UNVERIFIED', reconciliation_required: true, created_id: createdId, detail: vRes.reason });
      fail('PR_POST_WRITE_UNVERIFIED', `Remote verification failed for ${action} (${vRes.reason})`, EXIT_ERROR, {
        outcome: 'mutated_unverified', mutated: true, reconciliation_required: true, op_id: opId, ...(createdId ? { created_id: createdId } : {}), ...(prep.extraIds || {})
      });
    }
    if (vRes.postHead !== expectedHead || vRes.postState !== 'OPEN') {
      appendStateRecord(statePath, { ...pendingRecord, status: 'PR_POST_WRITE_HEAD_MOVED', reconciliation_required: true, created_id: createdId, remote_head: vRes.postHead, remote_state: vRes.postState });
      fail('PR_POST_WRITE_HEAD_MOVED', `PR state/HEAD changed concurrently after ${action} (state=${vRes.postState}, head=${expectedHead} -> ${vRes.postHead})`, EXIT_BLOCKED, {
        outcome: 'mutated_but_stale', mutated: true, reconciliation_required: true, op_id: opId, ...(createdId ? { created_id: createdId } : {}), ...(prep.extraIds || {}), expected_head: expectedHead, remote_head: vRes.postHead, remote_state: vRes.postState
      });
    }

    const finalPayload = onSuccessPayload(prep, header, createdId, vRes);
    appendStateRecord(statePath, { ...pendingRecord, status: finalPayload.status, reconciliation_required: false, created_id: createdId, head_sha: vRes.postHead });
    emit(finalPayload, EXIT_OK);
  });
}

// --- Subcommand 1: fetch (read-only; NEVER modifies/clears pending state) ---
function handleFetch(flags) {
  const repo = validateRepo(flags.repo);
  const prNumber = validatePr(flags.pr);
  const maxPages = validateMaxPages(flags['max-pages']);
  const includeResolved = Boolean(flags['include-resolved']);
  const includeBodies = Boolean(flags['include-bodies']);
  const selectedIds = flags['thread-id'] ? String(flags['thread-id']).split(',').map((s) => s.trim()).filter(Boolean).map((id) => validateId(id, '--thread-id')) : [];

  if (selectedIds.length > 0) {
    if (selectedIds.length > 50) fail('PR_INVALID_ARGS', 'At most 50 --thread-id values allowed');
    const header = fetchPrHeader(repo.owner, repo.name, prNumber);
    const reviewThreads = selectedIds.map((tid) => {
      const t = fetchSingleReviewThread(repo.full, prNumber, tid, maxPages, true);
      if (!t) fail('PR_TARGET_MISMATCH', `Review thread ${tid} does not belong to ${repo.full}#${prNumber}`);
      return {
        id: t.id, target_kind: 'review_thread', is_resolved: t.isResolved, is_outdated: t.isOutdated,
        path: frameUntrustedText(t.path), line: t.line, comment_count: t.comments.length,
        authors: [...new Set(t.comments.map((c) => c.author))].map(frameUntrustedText),
        comments: t.comments.map((c) => ({ id: c.id, author: frameUntrustedText(c.author), body: frameUntrustedText(c.body) }))
      };
    });
    emit({
      status: 'PR_FETCH_OK', retrieval_mode: 'targeted_threads', repo: repo.full, pr: prNumber, viewer: header.viewer,
      untrusted_data_framed: true, pull_request: { number: prNumber, state: header.state, head_sha: header.headSha },
      counts: { returned_review_threads: reviewThreads.length, general_comments: 0 }, review_threads: reviewThreads, general_comments: []
    }, EXIT_OK);
  }

  const { viewer, prMeta, threads } = fetchAllReviewThreads(repo.owner, repo.name, prNumber, maxPages, includeBodies);
  const rawGen = fetchRestPaginated(`repos/${repo.full}/issues/${prNumber}/comments`, maxPages);
  const visible = includeResolved ? threads : threads.filter((t) => !t.isResolved);
  const reviewThreads = visible.map((t) => ({
    id: t.id, target_kind: 'review_thread', is_resolved: t.isResolved, is_outdated: t.isOutdated,
    path: frameUntrustedText(t.path), line: t.line, comment_count: t.totalCount,
    authors: [...new Set(t.comments.map((c) => c.author))].map(frameUntrustedText),
    ...(includeBodies ? { comments: t.comments.map((c) => ({ id: c.id, author: frameUntrustedText(c.author), body: frameUntrustedText(c.body) })) } : (t.hasMoreNestedComments ? { nested_comments_omitted: true } : {}))
  }));
  const generalComments = rawGen.map((c) => ({
    id: String(c.id), target_kind: 'general_comment', resolvable: false, html_url: c.html_url ? String(c.html_url) : null,
    author: frameUntrustedText(c.user?.login || 'unknown'), ...(includeBodies ? { body: frameUntrustedText(c.body || '') } : {})
  }));
  emit({
    status: 'PR_FETCH_OK', retrieval_mode: includeBodies ? 'full_with_bodies' : 'metadata_first', repo: repo.full, pr: prNumber,
    viewer, untrusted_data_framed: true, include_resolved: includeResolved, include_bodies: includeBodies,
    pull_request: {
      number: prMeta.number, state: prMeta.state, head_sha: prMeta.headSha, title: frameUntrustedText(prMeta.title),
      base_ref: frameUntrustedText(prMeta.baseRefName), head_ref: frameUntrustedText(prMeta.headRefName),
      ...(includeBodies ? { body: frameUntrustedText(prMeta.body) } : {})
    },
    counts: { total_review_threads: threads.length, returned_review_threads: reviewThreads.length, general_comments: generalComments.length },
    review_threads: reviewThreads, general_comments: generalComments
  }, EXIT_OK);
}

// --- Subcommand 2: reconcile (R011: verifies specific pending ops against actual remote objects) ---
function handleReconcile(flags) {
  const repo = validateRepo(flags.repo);
  const prNumber = validatePr(flags.pr);
  const maxPages = validateMaxPages(flags['max-pages']);
  const gitCtx = resolveGitContext(flags['repo-root']);
  assertMutationOwnerAllowed(gitCtx, 'reconcile', flags['repo-root']);
  const statePath = resolveCanonicalStatePath(gitCtx.gitCommonDir, repo.full, prNumber);

  return withStateLock(statePath, 'reconcile', () => {
    const pending = getUnresolvedPendingRecords(readStateRecords(statePath), repo.full, prNumber);
    if (pending.length === 0) {
      emit({ status: 'PR_RECONCILE_OK', repo: repo.full, pr: prNumber, reconciled_count: 0, outcomes: [] }, EXIT_OK);
    }
    const header = fetchPrHeader(repo.owner, repo.name, prNumber);
    const outcomes = [];
    let hasUncertain = false;

    const classifyFound = (v, reviewedSha, label) => {
      if (!v.ok) return { outcome: 'UNCERTAIN', detail: v.reason };
      if (v.postHead === reviewedSha && v.postState === 'OPEN') return { outcome: 'CONFIRMED_SUCCESS', detail: `verified_${label}` };
      return { outcome: 'STALE_MUTATION', detail: `${label}_on_moved_or_nonopen_pr(${v.postState},${v.postHead})` };
    };

    for (const rec of pending) {
      const opId = rec.op_id || '__legacy__';
      const actor = String(rec.actor || header.viewer);
      const marker = rec.key && rec.op_hash ? `<!-- b3-pr-key:${rec.key};op=${rec.op_hash} -->` : '';
      let outcome = 'UNCERTAIN';
      let detail = 'unverifiable_record';
      let resolvedId = rec.created_id || null;

      if (rec.action === 'resolve' && rec.target_id) {
        const v = verifyRemoteObject({ kind: 'resolve_thread', repo: repo.full, pr: prNumber, viewer: actor, threadId: rec.target_id }, maxPages);
        if (!v.found) { outcome = 'UNCERTAIN'; detail = 'thread_not_found'; }
        else if (v.ok) ({ outcome, detail } = classifyFound(v, rec.reviewed_sha, 'resolve'));
        else if (!v.isResolved && rec.status === 'PENDING') { outcome = 'CONFIRMED_ABSENCE'; detail = 'thread_still_unresolved'; }
        else { outcome = 'UNCERTAIN'; detail = v.reason; }
      } else if ((rec.action === 'reply' && rec.target_kind === 'review_thread' && rec.target_id) ||
                 (rec.action === 'reply' && rec.target_kind === 'general_comment') ||
                 (rec.action === 'comment' && (rec.transport === 'issue_comment' || rec.transport === 'pull_review'))) {
        const kind = rec.target_kind === 'review_thread' ? 'review_thread_reply' : (rec.transport === 'pull_review' ? 'pull_review' : 'issue_comment');
        let cid = resolvedId;
        if (!cid && marker) {
          if (kind === 'review_thread_reply') {
            const th = fetchSingleReviewThread(repo.full, prNumber, rec.target_id, maxPages, true);
            const hit = th?.comments.find((c) => c.author.toLowerCase() === actor.toLowerCase() && c.body.includes(marker));
            if (hit) cid = hit.id;
          } else if (kind === 'issue_comment') {
            const hit = fetchRestPaginated(`repos/${repo.full}/issues/${prNumber}/comments`, maxPages).find((c) => String(c.user?.login || '').toLowerCase() === actor.toLowerCase() && String(c.body || '').includes(marker));
            if (hit) cid = String(hit.id);
          } else {
            const hit = fetchRestPaginated(`repos/${repo.full}/pulls/${prNumber}/reviews`, maxPages).find((r) => String(r.user?.login || '').toLowerCase() === actor.toLowerCase() && String(r.body || '').includes(marker));
            if (hit) cid = String(hit.id);
          }
        }
        if (cid) {
          resolvedId = cid;
          const v = verifyRemoteObject({
            kind, repo: repo.full, pr: prNumber, viewer: actor, createdId: cid, threadId: rec.target_id,
            expectedHead: rec.reviewed_sha, expectedBodySha256: rec.body_sha256, marker, event: rec.event, expectedInline: rec.expected_inline
          }, maxPages);
          if (!v.found) { outcome = 'UNCERTAIN'; detail = 'recorded_id_missing_remotely'; }
          else ({ outcome, detail } = classifyFound(v, rec.reviewed_sha, kind));
        } else if (rec.status === 'PENDING' && marker) {
          outcome = 'CONFIRMED_ABSENCE'; detail = `no_matching_${kind}_found`;
        } else {
          outcome = 'UNCERTAIN'; detail = 'missing_identity_for_reconciliation';
        }
      }

      outcomes.push({ op_id: opId, action: rec.action, outcome, detail, created_id: resolvedId, reviewed_sha: rec.reviewed_sha, remote_head: header.headSha, remote_state: header.state });
      if (outcome === 'CONFIRMED_SUCCESS') appendStateRecord(statePath, { op_id: opId, action: 'reconcile', status: 'RECONCILED_CONFIRMED', repo: repo.full, pr: prNumber, created_id: resolvedId, remote_head: header.headSha }, true);
      else if (outcome === 'CONFIRMED_ABSENCE') appendStateRecord(statePath, { op_id: opId, action: 'reconcile', status: 'RECONCILED_ABSENT', repo: repo.full, pr: prNumber, remote_head: header.headSha }, true);
      else if (outcome === 'STALE_MUTATION') appendStateRecord(statePath, { op_id: opId, action: 'reconcile', status: 'RECONCILED_STALE', repo: repo.full, pr: prNumber, created_id: resolvedId, reviewed_sha: rec.reviewed_sha, remote_head: header.headSha }, true);
      else hasUncertain = true;
    }

    if (hasUncertain) {
      fail('PR_RECONCILIATION_UNCERTAIN', 'One or more pending operations could not be safely reconciled; dependent writes remain blocked', EXIT_BLOCKED, {
        repo: repo.full, pr: prNumber, remote_head: header.headSha, outcomes
      });
    }
    emit({ status: 'PR_RECONCILE_OK', repo: repo.full, pr: prNumber, remote_head: header.headSha, reconciled_count: outcomes.length, outcomes }, EXIT_OK);
  });
}

// --- Subcommand 3: reply ---
function formatGeneralReplyWithRef(rawBody, targetId, htmlUrl) {
  const clean = normalizeText(rawBody);
  if ((htmlUrl && clean.includes(htmlUrl)) || clean.includes(`#issuecomment-${targetId}`)) return clean;
  const ref = htmlUrl && /^https?:\/\//i.test(htmlUrl) ? `> Replying to [comment #${targetId}](${htmlUrl})` : `> Replying to comment #${targetId} (#issuecomment-${targetId})`;
  return `${ref}\n\n${clean}`;
}

function handleReply(flags) {
  const repo = validateRepo(flags.repo);
  const prNumber = validatePr(flags.pr);
  const expectedHead = validateSha(flags['expected-head'], '--expected-head');
  const targetKind = flags['target-kind'];
  if (!ALLOWED_TARGET_KINDS.has(targetKind)) fail('PR_INVALID_ARGS', 'Invalid --target-kind (expected review_thread|general_comment)');
  const targetId = validateId(flags['target-id'], '--target-id');
  const rawBody = readSafeInputFile(flags['body-file'], '--body-file');
  if (!rawBody.trim()) fail('PR_INVALID_ARGS', '--body-file is empty');
  const explicitKey = validateKey(flags['idempotency-key']);
  const maxPages = validateMaxPages(flags['max-pages']);
  const isDraft = Boolean(flags.draft);
  const authWrite = Boolean(flags['authorize-write']);
  if (isDraft && authWrite) fail('PR_INVALID_ARGS', '--draft cannot be combined with --authorize-write');

  if (isDraft) {
    const previewBase = targetKind === 'general_comment' ? formatGeneralReplyWithRef(rawBody, targetId, null) : normalizeText(rawBody);
    const idObj = computeOperationIdentity({ repo: repo.full, pr: prNumber, actor: 'draft', op: 'reply', targetKind, targetId, reviewedSha: expectedHead, normalizedPayload: previewBase, explicitKey });
    const preview = appendMarker(previewBase, idObj.marker);
    if (preview.length > MAX_BODY_CHARS) fail('PR_FILE_GUARD', `Reply body exceeds ${MAX_BODY_CHARS} chars`);
    emit({ status: 'PR_DRAFT_OK', action: 'reply', mutated: false, repo: repo.full, pr: prNumber, expected_head: expectedHead, target_kind: targetKind, target_id: targetId, idempotency_key: idObj.key, operation_hash: idObj.opHash, body_preview: preview }, EXIT_OK);
  }
  if (!authWrite) fail('PR_AUTH_REQUIRED', 'Explicit --authorize-write is required to post a PR reply (or use --draft)', EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });

  const gitCtx = resolveGitContext(flags['repo-root']);
  assertMutationOwnerAllowed(gitCtx, 'reply', flags['repo-root']);
  const statePath = resolveCanonicalStatePath(gitCtx.gitCommonDir, repo.full, prNumber);

  return executeGuardedMutation({
    statePath, repo, prNumber, expectedHead, action: 'reply', maxPages,
    prepare(header) {
      let targetUrl = null;
      let baseBody = normalizeText(rawBody);
      let scanItems = [];
      if (targetKind === 'review_thread') {
        const thread = fetchSingleReviewThread(repo.full, prNumber, targetId, maxPages, true);
        if (!thread) fail('PR_TARGET_MISMATCH', `Review thread ${targetId} does not belong to ${repo.full}#${prNumber}`);
        scanItems = thread.comments;
      } else {
        const tRes = ghRestGet(`repos/${repo.full}/issues/comments/${targetId}`, { allowNotFound: true });
        if (tRes.notFound || !tRes.data || String(tRes.data.id) !== targetId || !String(tRes.data.issue_url || '').endsWith(`/issues/${prNumber}`)) {
          fail('PR_TARGET_MISMATCH', `General PR comment ${targetId} does not belong to ${repo.full}#${prNumber}`);
        }
        targetUrl = tRes.data.html_url ? String(tRes.data.html_url) : null;
        baseBody = formatGeneralReplyWithRef(rawBody, targetId, targetUrl);
        scanItems = fetchRestPaginated(`repos/${repo.full}/issues/${prNumber}/comments`, maxPages).map((c) => ({ id: c.id, author: c.user?.login || '', body: c.body || '' }));
      }
      const identity = computeOperationIdentity({ repo: repo.full, pr: prNumber, actor: header.viewer, op: 'reply', targetKind, targetId, reviewedSha: expectedHead, normalizedPayload: baseBody, explicitKey });
      const finalBody = appendMarker(baseBody, identity.marker);
      if (finalBody.length > MAX_BODY_CHARS) fail('PR_FILE_GUARD', `Reply body exceeds ${MAX_BODY_CHARS} chars`);

      const idem = checkIdempotencyWithRevalidation(scanItems, header.viewer, identity, (cand, expMarker) => (
        verifyRemoteObject({
          kind: targetKind === 'review_thread' ? 'review_thread_reply' : 'issue_comment',
          repo: repo.full, pr: prNumber, viewer: header.viewer, createdId: String(cand.id),
          threadId: targetKind === 'review_thread' ? targetId : undefined, expectedBody: baseBody, marker: expMarker
        }, maxPages)
      ));
      if (idem.status === 'COLLISION') fail('PR_KEY_COLLISION', `Idempotency key ${identity.key} already used for a different operation (${idem.existingId})`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false, existing_comment_id: idem.existingId, key: identity.key });
      if (idem.status === 'REMOTE_MISMATCH') fail('PR_REMOTE_STATE_MISMATCH', `Existing remote comment ${idem.existingId} with marker ${identity.key} does not match expected content/target (${idem.reason})`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false, existing_comment_id: idem.existingId, key: identity.key });
      if (idem.status === 'MATCH') {
        return {
          earlyEmit: { status: 'PR_IDEMPOTENT_SKIP', action: 'reply', mutated: false, target_kind: targetKind, target_id: targetId, key: identity.key, operation_hash: identity.opHash, existing_comment_id: idem.existingId },
          auditRecord: { op_id: `skip-${identity.opHash}`, action: 'reply', status: 'PR_IDEMPOTENT_SKIP', repo: repo.full, pr: prNumber, target_kind: targetKind, target_id: targetId, key: identity.key, op_hash: identity.opHash, comment_id: idem.existingId }
        };
      }
      return {
        baseBody, finalBody, identity, targetUrl, extraIds: { target_id: targetId },
        pendingMeta: { target_kind: targetKind, target_id: targetId, key: identity.key, op_hash: identity.opHash, body_sha256: sha256Hex(stripMarkers(baseBody)) }
      };
    },
    mutate(prep) {
      if (targetKind === 'review_thread') {
        const res = ghGraphQL('mutation($threadId: ID!, $body: String!) { addPullRequestReviewThreadReply(input: { pullRequestReviewThreadId: $threadId, body: $body }) { comment { id url } } }', { threadId: targetId, body: prep.finalBody });
        return { createdId: res.addPullRequestReviewThreadReply?.comment?.id, requireId: true };
      }
      return { createdId: ghRestPost(`repos/${repo.full}/issues/${prNumber}/comments`, { body: prep.finalBody })?.id, requireId: true };
    },
    verifySpec(prep, header, createdId) {
      return {
        kind: targetKind === 'review_thread' ? 'review_thread_reply' : 'issue_comment',
        repo: repo.full, pr: prNumber, viewer: header.viewer, createdId,
        threadId: targetKind === 'review_thread' ? targetId : undefined, expectedBody: prep.baseBody, marker: prep.identity.marker
      };
    },
    onSuccessPayload(prep, _header, createdId, vRes) {
      return {
        status: 'PR_REPLY_OK', action: 'reply', mutated: true, repo: repo.full, pr: prNumber, target_kind: targetKind, target_id: targetId,
        ...(prep.targetUrl ? { referenced_url: prep.targetUrl } : {}),
        comment_id: createdId, idempotency_key: prep.identity.key, operation_hash: prep.identity.opHash, verified_remote: true, verified_head: vRes.postHead
      };
    }
  });
}

// --- Subcommand 4: resolve (R001 canonical verify-check + R008 targeted thread) ---
function handleResolve(flags) {
  const repo = validateRepo(flags.repo);
  const prNumber = validatePr(flags.pr);
  const expectedHead = validateSha(flags['expected-head'], '--expected-head');
  const threadId = validateId(flags['thread-id'], '--thread-id');
  const fixCommit = validateSha(flags['fix-commit'], '--fix-commit');
  const maxPages = validateMaxPages(flags['max-pages']);
  const isDraft = Boolean(flags.draft);
  const authResolve = Boolean(flags['authorize-resolve']);

  if (isDraft && authResolve) fail('PR_INVALID_ARGS', '--draft cannot be combined with --authorize-resolve');
  if (/^[0-9]+$/.test(threadId) || threadId.startsWith('IC_')) fail('PR_NOT_RESOLVABLE', `General PR comments (${threadId}) cannot be resolved as review threads`);

  const gitCtx = resolveGitContext(flags['repo-root']);
  if (!isDraft) {
    if (!authResolve) fail('PR_AUTH_REQUIRED', 'Explicit --authorize-resolve is required to resolve a review thread (or use --draft)', EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
    assertMutationOwnerAllowed(gitCtx, 'resolve', flags['repo-root']);
  }
  if (!flags['evidence-file']) fail('PR_VERIFY_REQUIRED', '--evidence-file (bound to repo, PR, HEAD, thread, fix commit, and canonical b3-verify-v1 receipt) is required', EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
  const evidence = parseResolveEvidence(flags['evidence-file'], gitCtx.repoRoot, repo.full, prNumber, expectedHead, threadId, fixCommit);
  const pathsToVerify = [...new Set([evidence.targetPath, ...evidence.fixedPaths])];
  const verifyRes = runCanonicalVerifyCheck(gitCtx.repoRoot, evidence.receiptFullPath, expectedHead, evidence.checkedCommand, pathsToVerify);

  if (isDraft) {
    emit({ status: 'PR_DRAFT_OK', action: 'resolve', mutated: false, repo: repo.full, pr: prNumber, expected_head: expectedHead, thread_id: threadId, fix_commit: fixCommit, evidence_basis: evidence.basis, target_path: evidence.targetPath, verify_check: verifyRes.guardMessage, committed_tree_verified: true }, EXIT_OK);
  }

  const statePath = resolveCanonicalStatePath(gitCtx.gitCommonDir, repo.full, prNumber);

  return executeGuardedMutation({
    statePath, repo, prNumber, expectedHead, action: 'resolve', maxPages,
    prepare(header) {
      const thread = fetchSingleReviewThread(repo.full, prNumber, threadId, maxPages, false);
      if (!thread) {
        const gen = ghRestGet(`repos/${repo.full}/issues/comments/${threadId}`, { allowNotFound: true });
        if (!gen.notFound && gen.data && String(gen.data.issue_url || '').endsWith(`/issues/${prNumber}`)) {
          fail('PR_NOT_RESOLVABLE', `Target ${threadId} is a general PR comment and cannot be resolved`);
        }
        fail('PR_TARGET_MISMATCH', `Review thread ${threadId} does not belong to ${repo.full}#${prNumber}`);
      }
      if (!thread.path || evidence.targetPath !== thread.path) {
        fail('PR_VERIFY_REQUIRED', `Evidence target_path (${evidence.targetPath}) does not match thread path (${thread.path || 'missing'})`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
      }
      if (evidence.basis === 'DUPLICATE_FIXED') {
        const primary = fetchSingleReviewThread(repo.full, prNumber, evidence.primaryThreadId, maxPages, false);
        if (!primary || !primary.isResolved) {
          fail('PR_VERIFY_REQUIRED', `DUPLICATE_FIXED primary_thread_id (${evidence.primaryThreadId}) must exist on ${repo.full}#${prNumber} and be resolved first`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
        }
      }
      const cmp = ghRestGet(`repos/${repo.full}/compare/${fixCommit}...${header.headSha}`, { allowNotFound: true });
      const cmpStatus = String(cmp.data?.status || '');
      const behindBy = Number(cmp.data?.behind_by ?? -1);
      if (cmp.notFound || !(cmpStatus === 'identical' || (cmpStatus === 'ahead' && behindBy === 0))) {
        fail('PR_FIX_NOT_REMOTE', `Fix commit ${fixCommit} is not reachable in remote PR HEAD ${header.headSha}`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
      }
      const commitRes = ghRestGet(`repos/${repo.full}/commits/${fixCommit}`, { allowNotFound: true });
      const touched = new Set();
      for (const f of (Array.isArray(commitRes.data?.files) ? commitRes.data.files : [])) {
        if (f?.filename) touched.add(String(f.filename));
        if (f?.previous_filename) touched.add(String(f.previous_filename));
      }
      if (commitRes.notFound || !pathsToVerify.every((p) => touched.has(p))) {
        fail('PR_VERIFY_REQUIRED', `Remote fix commit ${fixCommit} does not modify all verified paths (${pathsToVerify.join(', ')})`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
      }
      if (thread.isResolved) {
        return {
          earlyEmit: { status: 'PR_ALREADY_RESOLVED', action: 'resolve', mutated: false, thread_id: threadId, verified_head: header.headSha },
          auditRecord: { op_id: `resolved-${threadId}`, action: 'resolve', status: 'PR_ALREADY_RESOLVED', repo: repo.full, pr: prNumber, target_id: threadId, fix_commit: fixCommit }
        };
      }
      return { extraIds: { thread_id: threadId }, pendingMeta: { target_id: threadId, fix_commit: fixCommit } };
    },
    beforeMutate() {
      runCanonicalVerifyCheck(gitCtx.repoRoot, evidence.receiptFullPath, expectedHead, evidence.checkedCommand, pathsToVerify);
    },
    mutate() {
      const res = ghGraphQL('mutation($threadId: ID!) { resolveReviewThread(input: { threadId: $threadId }) { thread { id isResolved } } }', { threadId });
      if (!res.resolveReviewThread?.thread?.isResolved) fail('PR_API_ERROR', 'resolveReviewThread did not confirm isResolved=true');
      return { createdId: threadId, requireId: false };
    },
    verifySpec(_prep, header) {
      return { kind: 'resolve_thread', repo: repo.full, pr: prNumber, viewer: header.viewer, threadId };
    },
    onSuccessPayload(_prep, _header, _createdId, vRes) {
      return {
        status: 'PR_RESOLVE_OK', action: 'resolve', mutated: true, repo: repo.full, pr: prNumber, thread_id: threadId,
        fix_commit: fixCommit, is_resolved: true, verify_check: verifyRes.guardMessage, committed_tree_verified: true, verified_remote: true, verified_head: vRes.postHead
      };
    }
  });
}

// --- Subcommand 5: comment (R006 + R013 + R014) ---
function parseAndValidateInlineJson(inlineJsonPath) {
  const raw = readSafeInputFile(inlineJsonPath, '--inline-json');
  let parsed;
  try { parsed = JSON.parse(raw); } catch { fail('PR_INVALID_ARGS', '--inline-json is not valid JSON'); }
  if (!Array.isArray(parsed) || parsed.length === 0) fail('PR_INVALID_ARGS', '--inline-json must be a non-empty JSON array');
  return parsed.map((item, idx) => {
    if (!item || typeof item !== 'object') fail('PR_INVALID_ARGS', `Inline finding[${idx}] must be an object`);
    if (item.status !== 'CONFIRMED') fail('PR_INVALID_ARGS', `Inline finding[${idx}] rejected: status must be CONFIRMED`);
    if (!ALLOWED_SEVERITIES.has(item.severity)) fail('PR_INVALID_ARGS', `Inline finding[${idx}] rejected: invalid severity`);
    const p = validateRelPath(String(item.path || ''), `Inline finding[${idx}].path`);
    if (!Number.isInteger(item.line) || item.line < 1) fail('PR_INVALID_ARGS', `Inline finding[${idx}] must have positive integer line`);
    const side = item.side ? String(item.side) : 'RIGHT';
    if (!ALLOWED_SIDES.has(side)) fail('PR_INVALID_ARGS', `Inline finding[${idx}] has invalid side (expected RIGHT|LEFT)`);
    const title = String(item.title || '').trim();
    const body = String(item.body || '').trim();
    const fix = String(item.suggested_fix || '').trim();
    if (!title || !body || !fix) fail('PR_INVALID_ARGS', `Inline finding[${idx}] requires non-empty title, body, and suggested_fix`);
    const formatted = `**[${item.severity}] — ${title}**\n\n${body}\n\n**Suggested fix:** ${fix}`;
    if (formatted.length > MAX_BODY_CHARS) fail('PR_FILE_GUARD', `Inline finding[${idx}] exceeds ${MAX_BODY_CHARS} chars`);
    return { path: p, line: item.line, side, body: formatted };
  });
}

function handleComment(flags) {
  const repo = validateRepo(flags.repo);
  const prNumber = validatePr(flags.pr);
  const expectedHead = validateSha(flags['expected-head'], '--expected-head');
  const mode = flags.mode;
  if (!ALLOWED_MODES.has(mode)) fail('PR_INVALID_ARGS', 'Invalid --mode (expected summary|inline|both)');
  const event = flags.event || 'COMMENT';
  if (!ALLOWED_EVENTS.has(event)) fail('PR_INVALID_ARGS', 'Invalid --event (expected COMMENT|APPROVE|REQUEST_CHANGES)');
  const authReviewEvent = flags['authorize-review-event'];
  if (authReviewEvent !== undefined && !['APPROVE', 'REQUEST_CHANGES'].includes(authReviewEvent)) fail('PR_INVALID_ARGS', 'Invalid --authorize-review-event');
  if (authReviewEvent !== undefined && event === 'COMMENT') fail('PR_INVALID_ARGS', '--authorize-review-event cannot be set when --event is COMMENT');
  const explicitKey = validateKey(flags['idempotency-key']);
  const maxPages = validateMaxPages(flags['max-pages']);
  const isDraft = Boolean(flags.draft);
  const authWrite = Boolean(flags['authorize-write']);
  if (isDraft && (authWrite || authReviewEvent !== undefined)) fail('PR_INVALID_ARGS', '--draft cannot be combined with --authorize-write or --authorize-review-event');

  let summaryBody = '';
  let inlineComments = [];
  if (mode === 'summary' || mode === 'both') {
    if (!flags['summary-file']) fail('PR_INVALID_ARGS', `--summary-file is required for --mode ${mode}`);
    summaryBody = normalizeText(readSafeInputFile(flags['summary-file'], '--summary-file'));
    if (!summaryBody) fail('PR_INVALID_ARGS', '--summary-file is empty');
  } else if (flags['summary-file']) {
    fail('PR_INVALID_ARGS', '--summary-file is not allowed with --mode inline');
  }
  if (mode === 'inline' || mode === 'both') {
    if (!flags['inline-json']) fail('PR_INVALID_ARGS', `--inline-json is required for --mode ${mode}`);
    inlineComments = parseAndValidateInlineJson(flags['inline-json']);
  } else if (flags['inline-json']) {
    fail('PR_INVALID_ARGS', '--inline-json is not allowed with --mode summary');
  }

  const canonicalPayload = JSON.stringify({ summary: summaryBody, inline: inlineComments });
  if (isDraft) {
    const idObj = computeOperationIdentity({ repo: repo.full, pr: prNumber, actor: 'draft', op: 'comment', targetKind: 'pr', targetId: String(prNumber), reviewedSha: expectedHead, mode, event, normalizedPayload: canonicalPayload, explicitKey });
    const preview = appendMarker(summaryBody, idObj.marker);
    if (preview.length > MAX_BODY_CHARS) fail('PR_FILE_GUARD', `Summary body exceeds ${MAX_BODY_CHARS} chars`);
    emit({ status: 'PR_DRAFT_OK', action: 'comment', mutated: false, repo: repo.full, pr: prNumber, expected_head: expectedHead, mode, event, idempotency_key: idObj.key, operation_hash: idObj.opHash, summary_preview: preview, inline_count: inlineComments.length, inline_preview: inlineComments }, EXIT_OK);
  }
  if (!authWrite) fail('PR_AUTH_REQUIRED', 'Explicit --authorize-write is required to publish PR comments (or use --draft)', EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
  if (event !== 'COMMENT' && authReviewEvent !== event) fail('PR_EVENT_UNAUTHORIZED', `Review event ${event} requires matching --authorize-review-event ${event}`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });

  const transport = (mode === 'summary' && event === 'COMMENT') ? 'issue_comment' : 'pull_review';
  const gitCtx = resolveGitContext(flags['repo-root']);
  assertMutationOwnerAllowed(gitCtx, 'comment', flags['repo-root']);
  const statePath = resolveCanonicalStatePath(gitCtx.gitCommonDir, repo.full, prNumber);

  return executeGuardedMutation({
    statePath, repo, prNumber, expectedHead, action: 'comment', maxPages,
    prepare(header) {
      if (inlineComments.length > 0) {
        const fileMap = new Map(fetchRestPaginated(`repos/${repo.full}/pulls/${prNumber}/files`, maxPages).filter((f) => f?.filename).map((f) => [String(f.filename), f]));
        for (const ic of inlineComments) {
          const fObj = fileMap.get(ic.path);
          if (!fObj) fail('PR_TARGET_MISMATCH', `Inline path ${ic.path} is not in PR ${repo.full}#${prNumber} changed files`, EXIT_ERROR, { outcome: 'blocked_before_write', mutated: false });
          const anchors = parseUnifiedDiffAnchors(fObj.patch);
          if (!anchors.ok) fail('PR_DIFF_UNAVAILABLE', `Diff patch for ${ic.path} cannot be validated (${anchors.reason}); cannot anchor ${ic.path}:${ic.line} (${ic.side})`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false });
          const validSet = ic.side === 'LEFT' ? anchors.leftLines : anchors.rightLines;
          if (!validSet.has(ic.line)) fail('PR_INVALID_ANCHOR', `Inline anchor ${ic.path}:${ic.line} (${ic.side}) is not present in PR diff hunks`, EXIT_ERROR, { outcome: 'blocked_before_write', mutated: false });
        }
      }
      const identity = computeOperationIdentity({ repo: repo.full, pr: prNumber, actor: header.viewer, op: 'comment', targetKind: 'pr', targetId: String(prNumber), reviewedSha: expectedHead, mode, event, normalizedPayload: canonicalPayload, explicitKey });
      const finalBody = appendMarker(summaryBody, identity.marker);
      if (finalBody.length > MAX_BODY_CHARS) fail('PR_FILE_GUARD', `Summary body exceeds ${MAX_BODY_CHARS} chars`);

      const issueComments = fetchRestPaginated(`repos/${repo.full}/issues/${prNumber}/comments`, maxPages).map((c) => ({ id: c.id, kind: 'issue_comment', author: c.user?.login || '', body: c.body || '' }));
      const reviews = fetchRestPaginated(`repos/${repo.full}/pulls/${prNumber}/reviews`, maxPages).map((r) => ({ id: r.id, kind: 'pull_review', author: r.user?.login || '', body: r.body || '' }));
      const idem = checkIdempotencyWithRevalidation([...issueComments, ...reviews], header.viewer, identity, (cand, expMarker) => {
        if (cand.kind !== transport) return { ok: false, reason: `transport_mismatch(${cand.kind}!=${transport})` };
        return verifyRemoteObject({
          kind: transport, repo: repo.full, pr: prNumber, viewer: header.viewer, createdId: String(cand.id),
          expectedHead, expectedBody: summaryBody, marker: expMarker, event, expectedInline: inlineComments
        }, maxPages);
      });

      if (idem.status === 'COLLISION') fail('PR_KEY_COLLISION', `Idempotency key ${identity.key} already used for a different comment/review (${idem.existingId})`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false, existing_id: idem.existingId, key: identity.key });
      if (idem.status === 'REMOTE_MISMATCH') fail('PR_REMOTE_STATE_MISMATCH', `Existing remote ${transport} ${idem.existingId} with marker ${identity.key} is inconsistent (${idem.reason})`, EXIT_BLOCKED, { outcome: 'blocked_before_write', mutated: false, existing_id: idem.existingId, key: identity.key });
      if (idem.status === 'MATCH') {
        return {
          earlyEmit: { status: 'PR_IDEMPOTENT_SKIP', action: 'comment', mutated: false, mode, key: identity.key, operation_hash: identity.opHash, existing_id: idem.existingId },
          auditRecord: { op_id: `skip-${identity.opHash}`, action: 'comment', status: 'PR_IDEMPOTENT_SKIP', repo: repo.full, pr: prNumber, mode, key: identity.key, op_hash: identity.opHash, existing_id: idem.existingId }
        };
      }
      return {
        finalBody, identity,
        pendingMeta: { mode, event, transport, key: identity.key, op_hash: identity.opHash, body_sha256: sha256Hex(stripMarkers(summaryBody)), expected_inline: inlineComments }
      };
    },
    mutate(prep) {
      if (transport === 'issue_comment') {
        return { createdId: ghRestPost(`repos/${repo.full}/issues/${prNumber}/comments`, { body: prep.finalBody })?.id, requireId: true };
      }
      const payload = { commit_id: expectedHead, event, body: prep.finalBody, ...(inlineComments.length > 0 ? { comments: inlineComments } : {}) };
      return { createdId: ghRestPost(`repos/${repo.full}/pulls/${prNumber}/reviews`, payload)?.id, requireId: true };
    },
    verifySpec(prep, header, createdId) {
      return { kind: transport, repo: repo.full, pr: prNumber, viewer: header.viewer, createdId, expectedHead, expectedBody: summaryBody, marker: prep.identity.marker, event, expectedInline: inlineComments };
    },
    onSuccessPayload(prep, _header, createdId, vRes) {
      return {
        status: 'PR_COMMENT_OK', action: 'comment', mutated: true, repo: repo.full, pr: prNumber, mode, event, transport,
        created_id: createdId, idempotency_key: prep.identity.key, operation_hash: prep.identity.opHash, inline_count: inlineComments.length, verified_remote: true, verified_head: vRes.postHead
      };
    }
  });
}

// --- Top-level entry with safe full stdout drain (R002) ---
process.stdout.on('error', (err) => {
  if (err && err.code === 'EPIPE') process.exitCode = process.exitCode || EXIT_ERROR;
});

try {
  const { cmd, flags } = parseArgs(process.argv.slice(2));
  if (cmd === 'fetch') handleFetch(flags);
  else if (cmd === 'reconcile') handleReconcile(flags);
  else if (cmd === 'reply') handleReply(flags);
  else if (cmd === 'resolve') handleResolve(flags);
  else if (cmd === 'comment') handleComment(flags);
} catch (err) {
  const payload = err instanceof B3Exit
    ? err.payload
    : { status: 'PR_API_ERROR', error: sanitizeUntrustedText(err?.message || String(err)).slice(0, 300) };
  process.exitCode = err instanceof B3Exit ? err.code : EXIT_ERROR;
  process.stdout.write(JSON.stringify(payload) + '\n', 'utf8');
}
