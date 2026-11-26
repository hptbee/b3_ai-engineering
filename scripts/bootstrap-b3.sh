#!/usr/bin/env bash
# Checksum-verified bootstrap & rollback helper for the native `b3` binary.
# Supports local offline release bundles (--release-dir) or GitHub Releases (--version).
# Usage:
#   ./scripts/bootstrap-b3.sh [--version latest|v0.1.0] [--release-dir DIR] [--install-dir DIR] [--repo OWNER/REPO] [--target TRIPLE] [--rollback] [--dry-run]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

VERSION="latest"
RELEASE_DIR=""
RELEASE_DIR_SET=false
INSTALL_DIR="${REPO_ROOT}/target/release"
INSTALL_DIR_SET=false
REPO="hptbee/b3_ai-engineering"
TARGET=""
ROLLBACK=false
DRY_RUN=false

fail() {
  echo "$1" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || fail "BOOTSTRAP_FAIL: missing value for --version"
      VERSION="$2"; shift 2 ;;
    --release-dir)
      [[ $# -ge 2 ]] || fail "BOOTSTRAP_FAIL: missing value for --release-dir"
      RELEASE_DIR="$2"; RELEASE_DIR_SET=true; shift 2 ;;
    --install-dir)
      [[ $# -ge 2 ]] || fail "BOOTSTRAP_FAIL: missing value for --install-dir"
      INSTALL_DIR="$2"; INSTALL_DIR_SET=true; shift 2 ;;
    --repo)
      [[ $# -ge 2 ]] || fail "BOOTSTRAP_FAIL: missing value for --repo"
      REPO="$2"; shift 2 ;;
    --target)
      [[ $# -ge 2 ]] || fail "BOOTSTRAP_FAIL: missing value for --target"
      TARGET="$2"; shift 2 ;;
    --rollback) ROLLBACK=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--version latest|TAG] [--release-dir DIR] [--install-dir DIR] [--repo OWNER/REPO] [--target TRIPLE] [--rollback] [--dry-run]"
      exit 0 ;;
    *) fail "BOOTSTRAP_FAIL: unknown argument '$1'" ;;
  esac
done

validate_nonempty_no_ctrl() {
  local val="$1" label="$2"
  local trimmed
  trimmed="$(printf '%s' "$val" | tr -d ' \t\r\n')"
  [[ -n "$trimmed" ]] || fail "BOOTSTRAP_FAIL: invalid $label (empty)"
  if printf '%s' "$val" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    fail "BOOTSTRAP_FAIL: invalid $label (control characters)"
  fi
}

has_dotdot_segment() {
  case "$1" in
    ..|*/..|../*|*/../*|*\\..|..\\*|*\\..\\*) return 0 ;;
    *) return 1 ;;
  esac
}

# 1. Strict input validation before constructing paths/URLs
if $INSTALL_DIR_SET; then
  validate_nonempty_no_ctrl "$INSTALL_DIR" "install-dir"
else
  validate_nonempty_no_ctrl "$INSTALL_DIR" "install-dir"
fi
has_dotdot_segment "$INSTALL_DIR" && fail "BOOTSTRAP_FAIL: invalid install-dir (path traversal '..' not allowed)"

if $RELEASE_DIR_SET; then
  validate_nonempty_no_ctrl "$RELEASE_DIR" "release-dir"
  has_dotdot_segment "$RELEASE_DIR" && fail "BOOTSTRAP_FAIL: invalid release-dir (path traversal '..' not allowed)"
fi

validate_nonempty_no_ctrl "$REPO" "repo"
if ! printf '%s\n' "$REPO" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
  fail "BOOTSTRAP_FAIL: invalid repo '$REPO'"
fi
case "$REPO" in
  *..*) fail "BOOTSTRAP_FAIL: invalid repo '$REPO'" ;;
  ./*|*/.|.) fail "BOOTSTRAP_FAIL: invalid repo '$REPO'" ;;
esac

validate_nonempty_no_ctrl "$VERSION" "version"
if [[ "$VERSION" != "latest" ]]; then
  case "$VERSION" in
    *..*) fail "BOOTSTRAP_FAIL: invalid version '$VERSION'" ;;
  esac
  if ! printf '%s\n' "$VERSION" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+([+-][A-Za-z0-9.-]+)?$'; then
    fail "BOOTSTRAP_FAIL: invalid version '$VERSION'"
  fi
fi

if [[ -z "$TARGET" ]]; then
  os_name="$(uname -s)"
  arch_name="$(uname -m)"
  case "${os_name}:${arch_name}" in
    Linux:x86_64|Linux:amd64) TARGET="x86_64-unknown-linux-gnu" ;;
    Darwin:arm64|Darwin:aarch64) TARGET="aarch64-apple-darwin" ;;
    Darwin:x86_64) TARGET="x86_64-apple-darwin" ;;
    MINGW*:x86_64|MSYS*:x86_64|CYGWIN*:x86_64) TARGET="x86_64-pc-windows-msvc" ;;
    *) fail "BOOTSTRAP_FAIL: unsupported platform ${os_name}/${arch_name}; pass --target explicitly" ;;
  esac
fi

case "$TARGET" in
  x86_64-pc-windows-msvc|x86_64-unknown-linux-gnu|aarch64-apple-darwin|x86_64-apple-darwin) ;;
  *) fail "BOOTSTRAP_FAIL: unsupported target '$TARGET'" ;;
esac

if [[ "$TARGET" == *windows* ]]; then
  DEST_NAME="b3.exe"
  ARTIFACT_NAME="b3-${TARGET}.exe"
else
  DEST_NAME="b3"
  ARTIFACT_NAME="b3-${TARGET}"
fi

# Lexical resolution against PWD without resolving symlinks
case "$INSTALL_DIR" in
  /*|[A-Za-z]:/*|[A-Za-z]:\\*) ;;
  *) INSTALL_DIR="${PWD%/}/${INSTALL_DIR}" ;;
esac
INSTALL_DIR="$(printf '%s' "$INSTALL_DIR" | awk '{ gsub(/\\/, "/"); gsub(/\/+/, "/"); while (gsub(/\/\.\//, "/")) {} sub(/\/\.$/, ""); if (length($0) > 1 && $0 !~ /^[A-Za-z]:\/$/) sub(/\/$/, ""); print }')"

DEST_PATH="${INSTALL_DIR}/${DEST_NAME}"
PREV_PATH="${DEST_PATH}.prev"
LOCK_DIR="${INSTALL_DIR}/.b3-bootstrap.lock"

assert_not_symlink() {
  local p="$1" label="$2"
  if [[ -L "$p" ]]; then
    fail "BOOTSTRAP_FAIL: refusing symlink $label at $p"
  fi
}

assert_ancestors_not_symlink() {
  local norm="$1"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    case "$norm" in
      /tmp) norm="/private/tmp" ;;
      /tmp/*) norm="/private/tmp${norm#/tmp}" ;;
      /var) norm="/private/var" ;;
      /var/*) norm="/private/var${norm#/var}" ;;
      /etc) norm="/private/etc" ;;
      /etc/*) norm="/private/etc${norm#/etc}" ;;
    esac
  fi
  local cur=""
  local rem="${norm#/}"
  case "$norm" in
    [A-Za-z]:/*)
      cur="${norm%%:*}:"
      rem="${norm#*:}"
      rem="${rem#/}"
      ;;
  esac
  local old_ifs="$IFS"
  local seg
  IFS='/'
  for seg in $rem; do
    [[ -z "$seg" || "$seg" == "." ]] && continue
    cur="${cur}/${seg}"
    if [[ -L "$cur" ]]; then
      IFS="$old_ifs"
      fail "BOOTSTRAP_FAIL: refusing symlink ancestor/dir at $cur"
    fi
  done
  IFS="$old_ifs"
}

can_smoke_test_target() {
  local os_name arch_name
  os_name="$(uname -s)"
  arch_name="$(uname -m)"
  case "${os_name}:${arch_name}:${TARGET}" in
    Linux:x86_64:x86_64-unknown-linux-gnu|Linux:amd64:x86_64-unknown-linux-gnu) return 0 ;;
    Darwin:arm64:aarch64-apple-darwin|Darwin:aarch64:aarch64-apple-darwin) return 0 ;;
    Darwin:x86_64:x86_64-apple-darwin) return 0 ;;
    MINGW*:x86_64:x86_64-pc-windows-msvc|MSYS*:x86_64:x86_64-pc-windows-msvc|CYGWIN*:x86_64:x86_64-pc-windows-msvc) return 0 ;;
    *) return 1 ;;
  esac
}

smoke_check_bin() {
  local bin="$1"
  if ! can_smoke_test_target; then
    printf '%s' '(cross-target; smoke skipped)'
    return 0
  fi
  local out
  if ! out="$("$bin" --version 2>&1)" || [[ "$out" != b3\ * ]]; then
    return 1
  fi
  printf '%s\n' "$out" | awk 'NR==1{print; exit}'
}

STAGING=""
SAME_FS_STAGED=""
PREV_TMP=""
RB_TMP=""
LOCK_HELD=false

cleanup() {
  if [[ -n "${STAGING:-}" ]]; then rm -rf "$STAGING" 2>/dev/null || true; fi
  if [[ -n "${SAME_FS_STAGED:-}" ]]; then rm -f "$SAME_FS_STAGED" 2>/dev/null || true; fi
  if [[ -n "${PREV_TMP:-}" ]]; then rm -f "$PREV_TMP" 2>/dev/null || true; fi
  if [[ -n "${RB_TMP:-}" ]]; then rm -f "$RB_TMP" 2>/dev/null || true; fi
  if [[ "${LOCK_HELD:-false}" == "true" ]]; then rmdir "$LOCK_DIR" 2>/dev/null || true; fi
}
trap cleanup EXIT

acquire_lock() {
  assert_not_symlink "$LOCK_DIR" ".b3-bootstrap.lock"
  local attempt=0
  while [[ $attempt -lt 10 ]]; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      LOCK_HELD=true
      return 0
    fi
    attempt=$((attempt + 1))
    if [[ $attempt -lt 10 ]]; then
      sleep 0.1
    fi
  done
  fail "BOOTSTRAP_FAIL: concurrent bootstrap in progress"
}

# 2. Ancestor & destination symlink rejection
assert_ancestors_not_symlink "$INSTALL_DIR"
if [[ -e "$INSTALL_DIR" && ! -d "$INSTALL_DIR" ]]; then
  fail "BOOTSTRAP_FAIL: install-dir is not a directory: $INSTALL_DIR"
fi
assert_not_symlink "$DEST_PATH" "$DEST_NAME"
if [[ -e "$DEST_PATH" && ! -f "$DEST_PATH" ]]; then
  fail "BOOTSTRAP_FAIL: destination is not a regular file: $DEST_PATH"
fi
assert_not_symlink "$PREV_PATH" "${DEST_NAME}.prev"
if [[ -e "$PREV_PATH" && ! -f "$PREV_PATH" ]]; then
  fail "BOOTSTRAP_FAIL: backup path is not a regular file: $PREV_PATH"
fi
assert_not_symlink "$LOCK_DIR" ".b3-bootstrap.lock"

if $ROLLBACK; then
  if [[ ! -f "$PREV_PATH" || ! -s "$PREV_PATH" ]]; then
    fail "ROLLBACK_FAIL: missing or empty backup binary at $PREV_PATH"
  fi
  if ! smoke_check_bin "$PREV_PATH" >/dev/null; then
    fail "ROLLBACK_FAIL: backup binary failed smoke check at $PREV_PATH"
  fi
  if $DRY_RUN; then
    echo "DRY_RUN: would restore $PREV_PATH -> $DEST_PATH"
    exit 0
  fi

  acquire_lock
  assert_ancestors_not_symlink "$INSTALL_DIR"
  assert_not_symlink "$DEST_PATH" "$DEST_NAME"
  assert_not_symlink "$PREV_PATH" "${DEST_NAME}.prev"
  if [[ ! -f "$PREV_PATH" || ! -s "$PREV_PATH" ]]; then
    fail "ROLLBACK_FAIL: missing or empty backup binary at $PREV_PATH"
  fi
  if ! smoke_check_bin "$PREV_PATH" >/dev/null; then
    fail "ROLLBACK_FAIL: backup binary failed smoke check at $PREV_PATH"
  fi

  RB_TMP="${DEST_PATH}.rb.$$.${RANDOM}"
  cp -f "$PREV_PATH" "$RB_TMP"
  chmod 0755 "$RB_TMP"
  mv -f "$RB_TMP" "$DEST_PATH"
  RB_TMP=""
  echo "ROLLBACK_OK: restored=$DEST_PATH"
  exit 0
fi

sha256_file() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print tolower($1)}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print tolower($1)}'
  else
    fail "BOOTSTRAP_FAIL: sha256sum or shasum is required"
  fi
}

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/b3-bootstrap-XXXXXX")"
SUMS_FILE="${STAGING}/SHA256SUMS.txt"
STAGED_BIN="${STAGING}/${ARTIFACT_NAME}"

if [[ -n "$RELEASE_DIR" ]]; then
  [[ -d "$RELEASE_DIR" ]] || fail "BOOTSTRAP_FAIL: release-dir not found: $RELEASE_DIR"
  [[ -f "${RELEASE_DIR}/SHA256SUMS.txt" ]] || fail "BOOTSTRAP_FAIL: missing SHA256SUMS.txt in $RELEASE_DIR"
  [[ -f "${RELEASE_DIR}/${ARTIFACT_NAME}" ]] || fail "BOOTSTRAP_FAIL: missing $ARTIFACT_NAME in $RELEASE_DIR"
  cp -f "${RELEASE_DIR}/SHA256SUMS.txt" "$SUMS_FILE"
  cp -f "${RELEASE_DIR}/${ARTIFACT_NAME}" "$STAGED_BIN"
else
  if ! command -v curl >/dev/null 2>&1; then
    fail "BOOTSTRAP_FAIL: curl is required for remote download"
  fi
  if [[ "$VERSION" == "latest" ]]; then
    BASE_URL="https://github.com/${REPO}/releases/latest/download"
  else
    BASE_URL="https://github.com/${REPO}/releases/download/${VERSION}"
  fi
  curl -fsSL "${BASE_URL}/SHA256SUMS.txt" -o "$SUMS_FILE"
  curl -fsSL "${BASE_URL}/${ARTIFACT_NAME}" -o "$STAGED_BIN"
fi

# 3. Strict SHA256SUMS.txt parsing (Bash 3.2 / BSD awk safe)
EXPECTED_SHA="$(awk -v art="$ARTIFACT_NAME" '
  {
    sub(/\r$/, "")
    if ($0 ~ /^[ \t]*$/) next
    nonblank++
    if (NF != 2 || length($1) != 64 || $1 !~ /^[0-9a-fA-F]+$/ || $0 !~ /^[0-9a-fA-F]+[ \t]+\*?(\.\/)?[A-Za-z0-9._-]+$/) {
      print "ERR:malformed"
      exit 2
    }
    h = tolower($1)
    f = $2
    sub(/^\*/, "", f)
    sub(/^\.\//, "", f)
    if (f == "." || f == ".." || index(f, "..") > 0) {
      print "ERR:invalid_name"
      exit 2
    }
    if (f in seen) {
      print "ERR:duplicate"
      exit 2
    }
    seen[f] = h
    if (f == art) {
      found = h
    }
  }
  END {
    if (nonblank == 0) { print "ERR:empty"; exit 2 }
    if (found == "") { print "ERR:missing"; exit 2 }
    print found
  }
' "$SUMS_FILE")" || fail "BOOTSTRAP_FAIL: invalid SHA256SUMS.txt for $ARTIFACT_NAME ($EXPECTED_SHA)"

if [[ -z "$EXPECTED_SHA" || "$EXPECTED_SHA" == ERR:* ]]; then
  fail "BOOTSTRAP_FAIL: invalid SHA256SUMS.txt for $ARTIFACT_NAME ($EXPECTED_SHA)"
fi

ACTUAL_SHA="$(sha256_file "$STAGED_BIN")"
if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
  fail "BOOTSTRAP_FAIL: sha256 mismatch for $ARTIFACT_NAME (expected=$EXPECTED_SHA actual=$ACTUAL_SHA)"
fi

chmod 0755 "$STAGED_BIN" || true

if $DRY_RUN; then
  if ! smoke_check_bin "$STAGED_BIN" >/dev/null; then
    fail "BOOTSTRAP_FAIL: dry-run smoke check failed for $STAGED_BIN"
  fi
  echo "DRY_RUN: verified sha256=$ACTUAL_SHA target=$TARGET dest=$DEST_PATH"
  exit 0
fi

# 4. Safe InstallDir creation, lock, same-FS staging, pre-activation smoke test, atomic replace
mkdir -p "$INSTALL_DIR"
assert_ancestors_not_symlink "$INSTALL_DIR"
assert_not_symlink "$DEST_PATH" "$DEST_NAME"
assert_not_symlink "$PREV_PATH" "${DEST_NAME}.prev"
acquire_lock
assert_ancestors_not_symlink "$INSTALL_DIR"
assert_not_symlink "$DEST_PATH" "$DEST_NAME"
assert_not_symlink "$PREV_PATH" "${DEST_NAME}.prev"

SAME_FS_STAGED="${DEST_PATH}.new.$$.${RANDOM}"
cp -f "$STAGED_BIN" "$SAME_FS_STAGED"
chmod 0755 "$SAME_FS_STAGED"
assert_not_symlink "$SAME_FS_STAGED" "staged-binary"

if ! ver_out="$(smoke_check_bin "$SAME_FS_STAGED")"; then
  fail "BOOTSTRAP_FAIL: pre-activation smoke check failed for $SAME_FS_STAGED"
fi

if [[ -f "$DEST_PATH" ]]; then
  PREV_TMP="${PREV_PATH}.tmp.$$.${RANDOM}"
  cp -f "$DEST_PATH" "$PREV_TMP"
  chmod 0755 "$PREV_TMP" || true
  mv -f "$PREV_TMP" "$PREV_PATH"
  PREV_TMP=""
fi

mv -f "$SAME_FS_STAGED" "$DEST_PATH"
SAME_FS_STAGED=""

echo "BOOTSTRAP_OK: target=$TARGET dest=$DEST_PATH sha256=$ACTUAL_SHA version=${ver_out}"
