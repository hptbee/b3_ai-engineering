#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -n "${B3_GH_BIN:-}" ]; then
  GH_CAND="$B3_GH_BIN"
  if [[ "$GH_CAND" != */* && "$GH_CAND" != *\\* ]]; then
    GH_RESOLVED="$(command -v "$GH_CAND" 2>/dev/null || true)"
    if [ -n "$GH_RESOLVED" ]; then
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

if [ -z "${B3_BASH_BIN:-}" ] && [ -n "${BASH:-}" ]; then
  B3_BASH_BIN="$(cygpath -m "$BASH" 2>/dev/null || printf '%s' "$BASH")"
  export B3_BASH_BIN
fi

if [[ "${B3_USE_LEGACY:-0}" != "1" ]]; then
  _b3_bin=""
  if [[ -n "${B3_BIN:-}" && -f "$B3_BIN" ]]; then
    _b3_bin="$B3_BIN"
  elif [[ -f "${SCRIPT_DIR}/../target/release/b3.exe" ]]; then
    _b3_bin="${SCRIPT_DIR}/../target/release/b3.exe"
  elif [[ -f "${SCRIPT_DIR}/../target/release/b3" ]]; then
    _b3_bin="${SCRIPT_DIR}/../target/release/b3"
  fi
  if [[ -n "$_b3_bin" ]]; then
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
  fi
fi

CORE_SCRIPT="$SCRIPT_DIR/lib/b3-pr-github.mjs"

if ! command -v node >/dev/null 2>&1; then
  printf '{"status":"PR_API_ERROR","error":"node is required to run b3-pr-github"}\n'
  exit 1
fi

if [ ! -f "$CORE_SCRIPT" ]; then
  printf '{"status":"PR_API_ERROR","error":"Missing scripts/lib/b3-pr-github.mjs"}\n'
  exit 1
fi

CORE_SCRIPT_WIN="$(cygpath -m "$CORE_SCRIPT" 2>/dev/null || printf '%s' "$CORE_SCRIPT")"

exec node "$CORE_SCRIPT_WIN" "$@"
