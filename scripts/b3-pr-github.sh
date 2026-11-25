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

exec node "$CORE_SCRIPT" "$@"
