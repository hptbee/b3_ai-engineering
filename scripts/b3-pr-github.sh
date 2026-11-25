#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

if [ -n "${B3_GH_BIN:-}" ]; then
  GH_CAND="$B3_GH_BIN"
  if [[ "$GH_CAND" != */* && "$GH_CAND" != *\\* ]]; then
    GH_RESOLVED="$(command -v "$GH_CAND" 2>/dev/null || true)"
    if [ -n "$GH_RESOLVED" ]; then
      GH_CAND="$GH_RESOLVED"
    fi
  fi
  B3_GH_BIN="$(cygpath -m "$GH_CAND" 2>/dev/null || printf '%s' "$GH_CAND")"
  export B3_GH_BIN
fi

if [ -z "${B3_BASH_BIN:-}" ] && [ -n "${BASH:-}" ]; then
  B3_BASH_BIN="$(cygpath -m "$BASH" 2>/dev/null || printf '%s' "$BASH")"
  export B3_BASH_BIN
fi

exec node "$CORE_SCRIPT_WIN" "$@"
