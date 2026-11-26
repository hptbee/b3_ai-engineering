#!/usr/bin/env bash
# Thin wrapper forwarding b3-guard subcommands to the native b3 binary.
set -euo pipefail

_B3_GUARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_B3_REPO_ROOT="$(cd "${_B3_GUARD_DIR}/.." && pwd)"

CMD="${1:-}"
if [[ -z "$CMD" ]]; then
  echo "usage: $0 fingerprint|check-freshness|precommit|snapshot|diff-scope|mechanical-check|check-wave|new-run|resolve-run|list-runs|prune|verify-run|verify-check|symbol-check|check-worktree|review-inventory|review-ledger|evidence-check|merge-policy-check|context-cache [options]" >&2
  exit 1
fi
shift

case "$CMD" in
  fingerprint|check-freshness|snapshot|new-run|resolve-run|list-runs|prune|precommit|verify-run|verify-check|check-worktree|check-wave|symbol-check|diff-scope|mechanical-check|review-inventory|review-ledger|context-cache|evidence-check|merge-policy-check)
    ;;
  *)
    echo "unknown command: $CMD" >&2
    exit 1
    ;;
esac

_b3_bin=""
if [[ -n "${B3_BIN:-}" ]]; then
  if [[ -f "$B3_BIN" ]]; then
    _b3_bin="$B3_BIN"
  else
    echo "b3 native binary not found; build with 'cargo build --release' or set B3_BIN" >&2
    exit 1
  fi
elif [[ -f "${_B3_REPO_ROOT}/target/release/b3.exe" ]]; then
  _b3_bin="${_B3_REPO_ROOT}/target/release/b3.exe"
elif [[ -f "${_B3_REPO_ROOT}/target/release/b3" ]]; then
  _b3_bin="${_B3_REPO_ROOT}/target/release/b3"
elif [[ -f "${_B3_REPO_ROOT}/target/debug/b3.exe" ]]; then
  _b3_bin="${_B3_REPO_ROOT}/target/debug/b3.exe"
elif [[ -f "${_B3_REPO_ROOT}/target/debug/b3" ]]; then
  _b3_bin="${_B3_REPO_ROOT}/target/debug/b3"
elif command -v b3 >/dev/null 2>&1; then
  _b3_bin="$(command -v b3)"
else
  echo "b3 native binary not found; build with 'cargo build --release' or set B3_BIN" >&2
  exit 1
fi

_lpwd="$(pwd -L 2>/dev/null || pwd)"
case "$(uname -s 2>/dev/null || true)" in
  MINGW*|MSYS*|CYGWIN*)
    if [[ "$_lpwd" =~ ^/([A-Za-z])(/.*)?$ ]]; then
      _lpwd="${BASH_REMATCH[1]}:${BASH_REMATCH[2]:-/}"
    elif command -v cygpath >/dev/null 2>&1; then
      _lpwd="$(cygpath -m "$_lpwd" 2>/dev/null || printf '%s' "$_lpwd")"
    fi
    if [[ -n "${B3_GITHUB_VERIFY_ADAPTER:-}" ]] && command -v cygpath >/dev/null 2>&1; then
      B3_GITHUB_VERIFY_ADAPTER="$(cygpath -m "$B3_GITHUB_VERIFY_ADAPTER" 2>/dev/null || printf '%s' "$B3_GITHUB_VERIFY_ADAPTER")"
      export B3_GITHUB_VERIFY_ADAPTER
    fi
    ;;
esac

B3_LOGICAL_PWD="$_lpwd" exec "$_b3_bin" guard "$CMD" "$@"
