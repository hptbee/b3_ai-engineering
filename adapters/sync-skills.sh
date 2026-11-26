#!/usr/bin/env bash
# Activate canonical skills/, commands/, agents/ for a host in this B3 checkout via native `b3 sync`.
# Usage: ./adapters/sync-skills.sh [--dry-run] [--verify] [--force] <cursor|codex|claude|antigravity>

set -euo pipefail

DRY_RUN=false
VERIFY_ONLY=false
FORCE=false
TARGET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --verify) VERIFY_ONLY=true; shift ;;
    --force) FORCE=true; shift ;;
    cursor|codex|claude|antigravity) TARGET="$1"; shift ;;
    -h|--help)
      echo "Usage: $0 [--dry-run] [--verify] [--force] <cursor|codex|claude|antigravity>"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--dry-run] [--verify] [--force] <cursor|codex|claude|antigravity>" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  echo "Usage: $0 [--dry-run] [--verify] [--force] <cursor|codex|claude|antigravity>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

_b3_bin=""
if [[ -n "${B3_BIN:-}" ]]; then
  if [[ -f "$B3_BIN" ]]; then
    _b3_bin="$B3_BIN"
  else
    echo "b3 native binary not found; build with 'cargo build --release' or set B3_BIN" >&2
    exit 1
  fi
elif [[ -f "${ROOT}/target/release/b3.exe" ]]; then
  _b3_bin="${ROOT}/target/release/b3.exe"
elif [[ -f "${ROOT}/target/release/b3" ]]; then
  _b3_bin="${ROOT}/target/release/b3"
elif [[ -f "${ROOT}/target/debug/b3.exe" ]]; then
  _b3_bin="${ROOT}/target/debug/b3.exe"
elif [[ -f "${ROOT}/target/debug/b3" ]]; then
  _b3_bin="${ROOT}/target/debug/b3"
elif command -v b3 >/dev/null 2>&1; then
  _b3_bin="$(command -v b3)"
else
  echo "b3 native binary not found; build with 'cargo build --release' or set B3_BIN" >&2
  exit 1
fi

_root_arg="$ROOT"
if command -v cygpath >/dev/null 2>&1; then
  _root_arg="$(cygpath -m "$ROOT" 2>/dev/null || printf '%s' "$ROOT")"
fi

_sync_args=("sync" "--repo-root" "$_root_arg" "--host" "$TARGET")
if $DRY_RUN; then _sync_args+=("--dry-run"); fi
if $VERIFY_ONLY; then _sync_args+=("--verify-only"); fi
if $FORCE; then _sync_args+=("--force"); fi
exec "$_b3_bin" "${_sync_args[@]}"
