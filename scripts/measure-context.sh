#!/usr/bin/env bash
# Measure static context footprint via the native b3 binary.
# Usage: ./scripts/measure-context.sh [--repo-root DIR] [--strict]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
B3_HOME_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$B3_HOME_DIR"
STRICT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root)
      [[ $# -ge 2 ]] || { echo "missing value for $1" >&2; exit 1; }
      REPO_ROOT="$2"; shift 2 ;;
    --strict) STRICT=true; shift ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"

_b3_bin=""
if [[ -n "${B3_BIN:-}" ]]; then
  if [[ -f "$B3_BIN" ]]; then
    _b3_bin="$B3_BIN"
  else
    echo "b3 native binary not found; build with 'cargo build --release' or set B3_BIN" >&2
    exit 1
  fi
elif [[ -f "${B3_HOME_DIR}/target/release/b3.exe" ]]; then
  _b3_bin="${B3_HOME_DIR}/target/release/b3.exe"
elif [[ -f "${B3_HOME_DIR}/target/release/b3" ]]; then
  _b3_bin="${B3_HOME_DIR}/target/release/b3"
elif [[ -f "${B3_HOME_DIR}/target/debug/b3.exe" ]]; then
  _b3_bin="${B3_HOME_DIR}/target/debug/b3.exe"
elif [[ -f "${B3_HOME_DIR}/target/debug/b3" ]]; then
  _b3_bin="${B3_HOME_DIR}/target/debug/b3"
elif command -v b3 >/dev/null 2>&1; then
  _b3_bin="$(command -v b3)"
else
  echo "b3 native binary not found; build with 'cargo build --release' or set B3_BIN" >&2
  exit 1
fi

_repo_arg="$REPO_ROOT"
if command -v cygpath >/dev/null 2>&1; then
  _repo_arg="$(cygpath -m "$REPO_ROOT" 2>/dev/null || printf '%s' "$REPO_ROOT")"
fi

_b3_args=("context" "measure" "--repo-root=${_repo_arg}")
$STRICT && _b3_args+=("--strict")
exec "$_b3_bin" "${_b3_args[@]}"
