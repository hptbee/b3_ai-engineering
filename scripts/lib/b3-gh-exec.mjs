// Shared GitHub CLI resolution, safe cross-shell execution, and remote slug helpers.
// Used by scripts/lib/b3-github-verify.mjs and scripts/lib/b3-pr-github.mjs.

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

export function hasControlChars(val) {
  return /[\x00-\x1F\x7F]/.test(String(val ?? ''));
}

export function parseGitHubRemoteSlug(remoteUrl) {
  if (!remoteUrl) return '';
  const u = String(remoteUrl).trim();
  let m = u.match(/^https:\/\/(?:[^/@\s]+@)?github\.com\/([A-Za-z0-9._-]+\/[A-Za-z0-9._-]+?)(?:\.git)?\/?$/i);
  if (m) {
    return m[1].includes('..') ? '' : m[1];
  }
  m = u.match(/^(?:ssh:\/\/)?git@github\.com[:/]([A-Za-z0-9._-]+\/[A-Za-z0-9._-]+?)(?:\.git)?\/?$/i);
  if (m) {
    return m[1].includes('..') ? '' : m[1];
  }
  return '';
}

function isWindowsAppsStub(filePath) {
  if (process.platform !== 'win32') return false;
  const normBack = String(filePath || '').replace(/\//g, '\\');
  return /\\microsoft\\windowsapps\\/i.test(normBack);
}

function isExecutableOrFile(filePath) {
  if (!filePath || hasControlChars(filePath)) return false;
  if (isWindowsAppsStub(filePath)) return false;
  try {
    const st = fs.statSync(filePath);
    if (!st.isFile()) return false;
    if (process.platform === 'win32') return true;
    fs.accessSync(filePath, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function tryFileOrWinExts(candidate) {
  if (!candidate || hasControlChars(candidate)) return '';
  if (isExecutableOrFile(candidate)) return candidate;
  if (process.platform === 'win32' && !/\.[A-Za-z0-9]+$/.test(candidate)) {
    for (const ext of ['.exe', '.com', '.cmd', '.bat']) {
      if (isExecutableOrFile(candidate + ext)) return candidate + ext;
    }
  }
  return '';
}

function resolveWinMsysCandidate(candidateRaw) {
  const m = candidateRaw.match(/^\/([A-Za-z])\/(.*)$/);
  if (m) {
    const driveTranslated = `${m[1]}:\\${m[2].replace(/\//g, '\\')}`;
    const driveHit = tryFileOrWinExts(driveTranslated);
    if (driveHit) return driveHit;
  }

  const bashBin = resolveBashBinary();
  if (!bashBin) return '';
  const bashDir = path.dirname(bashBin);
  const cygCands = [
    path.join(bashDir, 'cygpath.exe'),
    path.resolve(bashDir, '..', 'usr', 'bin', 'cygpath.exe'),
  ];
  let cygOut = '';
  let resolvedViaExe = false;
  for (const cygBin of cygCands) {
    if (isExecutableOrFile(cygBin)) {
      const r = spawnSync(cygBin, ['-w', '--', candidateRaw], {
        encoding: 'utf8',
        windowsHide: true,
        timeout: 5000,
      });
      if (!r.error && r.status === 0) {
        cygOut = String(r.stdout || '').trim();
        resolvedViaExe = true;
      }
      break;
    }
  }
  if (!resolvedViaExe) {
    const r = spawnSync(bashBin, ['-c', 'cygpath -w -- "$1"', '_', candidateRaw], {
      encoding: 'utf8',
      windowsHide: true,
      timeout: 5000,
    });
    if (!r.error && r.status === 0) {
      cygOut = String(r.stdout || '').trim();
    }
  }
  return cygOut ? tryFileOrWinExts(cygOut) : '';
}

let cachedGhKey = null;
let cachedGhVal = '';

export function resolveGhBinary(explicitGh = '') {
  const candidateRaw = String(explicitGh || process.env.B3_GH_BIN || '').trim();
  const pathEnv = process.env.PATH || process.env.Path || '';
  const cacheKey = `${candidateRaw}\0${pathEnv}`;
  if (cachedGhKey === cacheKey) return cachedGhVal;

  const finish = (val) => {
    cachedGhKey = cacheKey;
    cachedGhVal = val;
    return val;
  };

  if (hasControlChars(candidateRaw)) return finish('');
  const isWin = process.platform === 'win32';
  const dirs = pathEnv.split(path.delimiter).filter(Boolean);

  if (candidateRaw) {
    if (candidateRaw.includes('/') || candidateRaw.includes('\\') || (isWin && /^[A-Za-z]:/.test(candidateRaw))) {
      const directHit = tryFileOrWinExts(candidateRaw);
      if (directHit) return finish(directHit);
      if (isWin && candidateRaw.startsWith('/') && !candidateRaw.startsWith('//')) {
        const msysHit = resolveWinMsysCandidate(candidateRaw);
        if (msysHit) return finish(msysHit);
      }
      return finish('');
    }
    const names = isWin && !/\.[A-Za-z0-9]+$/.test(candidateRaw)
      ? [`${candidateRaw}.exe`, `${candidateRaw}.com`, `${candidateRaw}.cmd`, `${candidateRaw}.bat`, candidateRaw]
      : [candidateRaw];
    for (const d of dirs) {
      for (const n of names) {
        const full = path.join(d, n);
        if (isExecutableOrFile(full)) return finish(full);
      }
    }
    return finish('');
  }

  const names = isWin ? ['gh.exe', 'gh.com', 'gh.cmd', 'gh.bat', 'gh'] : ['gh'];
  for (const d of dirs) {
    for (const n of names) {
      const full = path.join(d, n);
      if (isExecutableOrFile(full)) return finish(full);
    }
  }
  return finish('');
}

let cachedBashKey = null;
let cachedBashVal = '';

export function resolveBashBinary(explicitBash = '') {
  const raw = String(explicitBash || process.env.B3_BASH_BIN || '').trim();
  const pathEnv = process.env.PATH || process.env.Path || '';
  const cacheKey = `${raw}\0${pathEnv}`;
  if (cachedBashKey === cacheKey) return cachedBashVal;

  const finish = (val) => {
    cachedBashKey = cacheKey;
    cachedBashVal = val;
    return val;
  };

  const isWin = process.platform === 'win32';
  if (raw) {
    if (hasControlChars(raw)) return finish('');
    const directBash = tryFileOrWinExts(raw);
    if (directBash) return finish(directBash);
    if (isWin && raw.startsWith('/') && !raw.startsWith('//')) {
      const m = raw.match(/^\/([A-Za-z])\/(.*)$/);
      if (m) {
        const driveBash = tryFileOrWinExts(`${m[1]}:\\${m[2].replace(/\//g, '\\')}`);
        if (driveBash) return finish(driveBash);
      }
    }
    return finish('');
  }

  if (isWin) {
    const winCands = [];
    if (process.env.ProgramFiles) {
      winCands.push(path.join(process.env.ProgramFiles, 'Git', 'bin', 'bash.exe'));
      winCands.push(path.join(process.env.ProgramFiles, 'Git', 'usr', 'bin', 'bash.exe'));
    }
    winCands.push(
      'C:\\Program Files\\Git\\bin\\bash.exe',
      'C:\\Program Files\\Git\\usr\\bin\\bash.exe',
      'C:\\Program Files (x86)\\Git\\bin\\bash.exe'
    );
    for (const cand of winCands) {
      if (isExecutableOrFile(cand)) return finish(cand);
    }
  }
  const dirs = pathEnv.split(path.delimiter).filter(Boolean);
  for (const d of dirs) {
    const full = path.join(d, isWin ? 'bash.exe' : 'bash');
    if (isWin) {
      const normBack = full.replace(/\//g, '\\');
      if (/\\windows\\(system32|sysnative)\\bash\.exe$/i.test(normBack) || /\\microsoft\\windowsapps\\bash\.exe$/i.test(normBack)) {
        continue;
      }
    }
    if (isExecutableOrFile(full)) return finish(full);
  }
  return finish('');
}

export function execGh(args, options = {}) {
  const ghBin = options.ghBin || resolveGhBinary(options.explicitGh || '');
  if (!ghBin) {
    return { ok: false, reason: 'gh_not_found', error: new Error('gh CLI not found in PATH'), status: null, stdout: '', stderr: '', ghBin: '' };
  }
  if (hasControlChars(ghBin) || ghBin.includes('"')) {
    return { ok: false, reason: 'unsafe_gh_path', error: new Error('Unsafe path for gh CLI rejected'), status: null, stdout: '', stderr: '', ghBin };
  }

  const isWin = process.platform === 'win32';
  const strArgs = Array.isArray(args) ? args.map((a) => String(a)) : [];
  for (const a of strArgs) {
    if (hasControlChars(a)) {
      return { ok: false, reason: 'unsafe_gh_arg', error: new Error('Control characters rejected in gh CLI arguments'), status: null, stdout: '', stderr: '', ghBin };
    }
  }

  const baseEnv = {
    ...process.env,
    ...(options.env || {}),
    GH_PROMPT_DISABLED: '1',
  };
  const spawnOpts = {
    encoding: options.encoding || 'utf8',
    windowsHide: true,
    maxBuffer: options.maxBuffer || 64 * 1024 * 1024,
    timeout: options.timeout ?? 60000,
    env: baseEnv,
  };
  if (options.stdin !== undefined && options.stdin !== null) {
    spawnOpts.input = options.stdin;
  }

  let r;
  if (isWin && /\.(cmd|bat)$/i.test(ghBin)) {
    if (/[!"&|<>^%()]/.test(ghBin)) {
      return { ok: false, reason: 'unsafe_gh_path', error: new Error('Unsafe Windows batch path for gh CLI rejected'), status: null, stdout: '', stderr: '', ghBin };
    }
    for (const a of strArgs) {
      if (a.includes('"') || /\\$/.test(a)) {
        return { ok: false, reason: 'unsafe_gh_arg', error: new Error('Unsafe argument rejected for Windows batch gh CLI'), status: null, stdout: '', stderr: '', ghBin };
      }
    }
    const comSpec = baseEnv.ComSpec || baseEnv.COMSPEC || 'cmd.exe';
    if (hasControlChars(comSpec) || /["&|<>^%!]/.test(comSpec)) {
      return { ok: false, reason: 'unsafe_comspec', error: new Error('Unsafe ComSpec rejected'), status: null, stdout: '', stderr: '', ghBin };
    }
    const cmdEnv = { ...baseEnv, B3_GH_CMD_EXE: ghBin };
    const tokens = [];
    for (let idx = 0; idx < strArgs.length; idx += 1) {
      if (strArgs[idx] === '') {
        tokens.push('""');
      } else {
        const k = `B3_GH_CMD_${idx}`;
        cmdEnv[k] = strArgs[idx];
        tokens.push(`"%${k}%"`);
      }
    }
    const cmdLine = '"' + ['"%B3_GH_CMD_EXE%"', ...tokens].join(' ') + '"';
    r = spawnSync(comSpec, ['/d', '/v:off', '/s', '/c', cmdLine], {
      ...spawnOpts,
      env: cmdEnv,
      windowsVerbatimArguments: true,
    });
  } else if (isWin && !/\.(exe|com)$/i.test(ghBin)) {
    const bashBin = options.bashBin || resolveBashBinary(options.explicitBash || '');
    if (!bashBin || hasControlChars(bashBin)) {
      return { ok: false, reason: 'bash_not_found', error: new Error('Git Bash not found to run POSIX gh script on Windows'), status: null, stdout: '', stderr: '', ghBin };
    }
    r = spawnSync(bashBin, ['--', ghBin.replace(/\\/g, '/'), ...strArgs], {
      ...spawnOpts,
      shell: false,
    });
  } else {
    r = spawnSync(ghBin, strArgs, {
      ...spawnOpts,
      shell: false,
    });
  }

  if (r.error) {
    if (r.error.code === 'ETIMEDOUT') {
      return { ok: false, reason: 'timeout', error: r.error, status: null, stdout: '', stderr: '', ghBin };
    }
    return { ok: false, reason: 'spawn_error', error: r.error, status: null, stdout: '', stderr: '', ghBin };
  }
  return {
    ok: true,
    status: typeof r.status === 'number' ? r.status : 1,
    stdout: r.stdout || '',
    stderr: r.stderr || '',
    signal: r.signal || null,
    ghBin,
  };
}
