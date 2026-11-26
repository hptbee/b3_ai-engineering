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
INSTALL_DIR="${REPO_ROOT}/target/release"
REPO="hptbee/b3_ai-engineering"
TARGET=""
ROLLBACK=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --release-dir) RELEASE_DIR="${2:-}"; shift 2 ;;
    --install-dir) INSTALL_DIR="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --target) TARGET="${2:-}"; shift 2 ;;
    --rollback) ROLLBACK=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--version latest|TAG] [--release-dir DIR] [--install-dir DIR] [--repo OWNER/REPO] [--target TRIPLE] [--rollback] [--dry-run]"
      exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

assert_not_symlink() {
  local p="$1" label="$2"
  if [[ -L "$p" ]]; then
    echo "BOOTSTRAP_FAIL: refusing symlink $label at $p" >&2
    exit 1
  fi
}

if [[ -z "$TARGET" ]]; then
  os_name="$(uname -s)"
  arch_name="$(uname -m)"
  case "${os_name}:${arch_name}" in
    Linux:x86_64|Linux:amd64) TARGET="x86_64-unknown-linux-gnu" ;;
    Darwin:arm64|Darwin:aarch64) TARGET="aarch64-apple-darwin" ;;
    Darwin:x86_64) TARGET="x86_64-apple-darwin" ;;
    MINGW*:x86_64|MSYS*:x86_64|CYGWIN*:x86_64) TARGET="x86_64-pc-windows-msvc" ;;
    *) echo "BOOTSTRAP_FAIL: unsupported platform ${os_name}/${arch_name}; pass --target explicitly" >&2; exit 1 ;;
  esac
fi

if [[ "$TARGET" == *windows* ]]; then
  DEST_NAME="b3.exe"
  ARTIFACT_NAME="b3-${TARGET}.exe"
else
  DEST_NAME="b3"
  ARTIFACT_NAME="b3-${TARGET}"
fi

DEST_PATH="${INSTALL_DIR}/${DEST_NAME}"
PREV_PATH="${DEST_PATH}.prev"

assert_not_symlink "$INSTALL_DIR" "install-dir"
assert_not_symlink "$DEST_PATH" "$DEST_NAME"
assert_not_symlink "$PREV_PATH" "${DEST_NAME}.prev"

if $ROLLBACK; then
  if [[ ! -f "$PREV_PATH" ]]; then
    echo "ROLLBACK_FAIL: missing backup binary at $PREV_PATH" >&2
    exit 1
  fi
  if $DRY_RUN; then
    echo "DRY_RUN: would restore $PREV_PATH -> $DEST_PATH"
    exit 0
  fi
  cp -f "$PREV_PATH" "$DEST_PATH"
  chmod +x "$DEST_PATH" || true
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
    echo "BOOTSTRAP_FAIL: sha256sum or shasum is required" >&2
    exit 1
  fi
}

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/b3-bootstrap-XXXXXX")"
cleanup() { rm -rf "$STAGING" 2>/dev/null || true; }
trap cleanup EXIT

SUMS_FILE="${STAGING}/SHA256SUMS.txt"
STAGED_BIN="${STAGING}/${ARTIFACT_NAME}"

if [[ -n "$RELEASE_DIR" ]]; then
  [[ -d "$RELEASE_DIR" ]] || { echo "BOOTSTRAP_FAIL: release-dir not found: $RELEASE_DIR" >&2; exit 1; }
  [[ -f "${RELEASE_DIR}/SHA256SUMS.txt" ]] || { echo "BOOTSTRAP_FAIL: missing SHA256SUMS.txt in $RELEASE_DIR" >&2; exit 1; }
  [[ -f "${RELEASE_DIR}/${ARTIFACT_NAME}" ]] || { echo "BOOTSTRAP_FAIL: missing $ARTIFACT_NAME in $RELEASE_DIR" >&2; exit 1; }
  cp -f "${RELEASE_DIR}/SHA256SUMS.txt" "$SUMS_FILE"
  cp -f "${RELEASE_DIR}/${ARTIFACT_NAME}" "$STAGED_BIN"
else
  if ! command -v curl >/dev/null 2>&1; then
    echo "BOOTSTRAP_FAIL: curl is required for remote download" >&2
    exit 1
  fi
  if [[ "$VERSION" == "latest" ]]; then
    BASE_URL="https://github.com/${REPO}/releases/latest/download"
  else
    BASE_URL="https://github.com/${REPO}/releases/download/${VERSION}"
  fi
  curl -fsSL "${BASE_URL}/SHA256SUMS.txt" -o "$SUMS_FILE"
  curl -fsSL "${BASE_URL}/${ARTIFACT_NAME}" -o "$STAGED_BIN"
fi

EXPECTED_SHA="$(awk -v art="$ARTIFACT_NAME" '
  {
    h = tolower($1)
    f = $2
    sub(/^\*/, "", f)
    sub(/^\.\//, "", f)
    if (h ~ /^[0-9a-f]{64}$/ && f == art) { print h; exit }
  }
' "$SUMS_FILE")"

if [[ -z "$EXPECTED_SHA" ]]; then
  echo "BOOTSTRAP_FAIL: no checksum entry for $ARTIFACT_NAME in SHA256SUMS.txt" >&2
  exit 1
fi

ACTUAL_SHA="$(sha256_file "$STAGED_BIN")"
if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
  echo "BOOTSTRAP_FAIL: sha256 mismatch for $ARTIFACT_NAME (expected=$EXPECTED_SHA actual=$ACTUAL_SHA)" >&2
  exit 1
fi

if $DRY_RUN; then
  echo "DRY_RUN: verified sha256=$ACTUAL_SHA target=$TARGET dest=$DEST_PATH"
  exit 0
fi

mkdir -p "$INSTALL_DIR"
assert_not_symlink "$INSTALL_DIR" "install-dir"
chmod +x "$STAGED_BIN" || true

HAD_PREV=false
if [[ -f "$DEST_PATH" ]]; then
  cp -f "$DEST_PATH" "$PREV_PATH"
  HAD_PREV=true
fi

cp -f "$STAGED_BIN" "$DEST_PATH"
chmod +x "$DEST_PATH" || true

if ver_out="$("$DEST_PATH" --version 2>&1)" && [[ "$ver_out" == b3\ * ]]; then
  echo "BOOTSTRAP_OK: target=$TARGET dest=$DEST_PATH sha256=$ACTUAL_SHA version=${ver_out}"
  exit 0
fi

if $HAD_PREV && [[ -f "$PREV_PATH" ]]; then
  cp -f "$PREV_PATH" "$DEST_PATH"
  chmod +x "$DEST_PATH" || true
else
  rm -f "$DEST_PATH"
fi
echo "BOOTSTRAP_FAIL: post-install verification failed (rolled back)" >&2
exit 1
