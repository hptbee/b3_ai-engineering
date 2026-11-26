#!/usr/bin/env bash
# Thin Bash shim forwarding to native `b3 pr`.
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

if [[ -z "${B3_BASH_BIN:-}" && -n "${BASH:-}" ]]; then
  B3_BASH_BIN="$(cygpath -m "$BASH" 2>/dev/null || printf '%s' "$BASH")"
  export B3_BASH_BIN
fi

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

if [[ $# -eq 0 ]]; then
  printf '{"status":"PR_INVALID_ARGS","error":"Missing subcommand (expected: fetch, reply, resolve, comment, reconcile)"}\n'
  exit 1
fi
case "$1" in
  fetch|reconcile|reply|resolve|comment) ;;
  *)
    printf '{"status":"PR_INVALID_ARGS","error":"Unknown subcommand (expected: fetch, reply, resolve, comment, reconcile)"}\n'
    exit 1
    ;;
esac

exec "$_b3_bin" pr "$@"
