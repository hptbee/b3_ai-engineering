#!/usr/bin/env bash
# Thin optional GitHub verification wrapper forwarding to native `b3 pr verify`.
# Usage: ./scripts/b3-github-verify.sh --mode pre-merge|post-merge [--repo-root <dir>] [--repo <owner/name>] --pr-number <N>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
B3_HOME_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -n "${B3_GH_BIN:-}" ]]; then
  GH_CAND="$B3_GH_BIN"
  if [[ "$GH_CAND" != */* && "$GH_CAND" != *\\* ]]; then
    GH_RESOLVED="$(command -v "$GH_CAND" 2>/dev/null || true)"
    if [[ -n "$GH_RESOLVED" ]]; then
      GH_CAND="$GH_RESOLVED"
    fi
  fi
  if [[ "$GH_CAND" == */* || "$GH_CAND" == *\\* ]]; then
    B3_GH_BIN="$(cygpath -m "$GH_CAND" 2>/dev/null || printf '%s' "$GH_CAND")"
  else
    B3_GH_BIN="$GH_CAND"
  fi
  export B3_GH_BIN
fi

_b3_bin=""
if [[ -n "${B3_BIN:-}" ]]; then
  if [[ -f "$B3_BIN" ]]; then
    _b3_bin="$B3_BIN"
  else
    echo "GH_VERIFY_UNAVAILABLE: b3_binary_unavailable (build with 'cargo build --release' or set B3_BIN)" >&2
    exit 2
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
  echo "GH_VERIFY_UNAVAILABLE: b3_binary_unavailable (build with 'cargo build --release' or set B3_BIN)" >&2
  exit 2
fi

exec "$_b3_bin" pr verify "$@"
