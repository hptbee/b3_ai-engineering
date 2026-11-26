#!/usr/bin/env bash
# Global Antigravity plugin lifecycle manager for B3 AI Engineering (macOS / Linux / Git Bash).
# Usage: ./adapters/antigravity/install-plugin.sh [install|update|verify|uninstall] [--plugin-root PATH] [--b3-home PATH] [--user-home PATH] [--dry-run] [--force]
set -euo pipefail

ACTION="install"
ACTION_SET=false
PLUGIN_ROOT=""
B3_HOME=""
USER_HOME=""
DRY_RUN=false
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    install|update|verify|uninstall)
      if $ACTION_SET; then echo "error: duplicate action '$1'" >&2; exit 1; fi
      ACTION="$1"; ACTION_SET=true; shift ;;
    --action)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "error: option $1 requires a value" >&2; exit 1; }
      if $ACTION_SET; then echo "error: duplicate action '$2'" >&2; exit 1; fi
      case "$2" in
        install|update|verify|uninstall) ACTION="$2"; ACTION_SET=true ;;
        *) echo "error: invalid action '$2'" >&2; exit 1 ;;
      esac
      shift 2 ;;
    --plugin-root)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "error: option $1 requires a value" >&2; exit 1; }
      PLUGIN_ROOT="$2"; shift 2 ;;
    --b3-home)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "error: option $1 requires a value" >&2; exit 1; }
      B3_HOME="$2"; shift 2 ;;
    --user-home)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "error: option $1 requires a value" >&2; exit 1; }
      USER_HOME="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --force) FORCE=true; shift ;;
    -h|--help)
      echo "Usage: $0 [install|update|verify|uninstall] [--plugin-root PATH] [--b3-home PATH] [--user-home PATH] [--dry-run] [--force]"
      exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_b3_repo_default="$(cd "${SCRIPT_DIR}/../.." && pwd)"

_b3_bin=""
if [[ -n "${B3_BIN:-}" ]]; then
  if [[ -f "$B3_BIN" ]]; then
    _b3_bin="$B3_BIN"
  else
    echo "b3 native binary not found; build with 'cargo build --release' or set B3_BIN" >&2
    exit 1
  fi
elif [[ -f "${_b3_repo_default}/target/release/b3.exe" ]]; then
  _b3_bin="${_b3_repo_default}/target/release/b3.exe"
elif [[ -f "${_b3_repo_default}/target/release/b3" ]]; then
  _b3_bin="${_b3_repo_default}/target/release/b3"
elif [[ -f "${_b3_repo_default}/target/debug/b3.exe" ]]; then
  _b3_bin="${_b3_repo_default}/target/debug/b3.exe"
elif [[ -f "${_b3_repo_default}/target/debug/b3" ]]; then
  _b3_bin="${_b3_repo_default}/target/debug/b3"
elif command -v b3 >/dev/null 2>&1; then
  _b3_bin="$(command -v b3)"
else
  echo "b3 native binary not found; build with 'cargo build --release' or set B3_BIN" >&2
  exit 1
fi

_eff_home="${B3_HOME:-$_b3_repo_default}"
_pr_arg="$PLUGIN_ROOT"
_uh_arg="$USER_HOME"
if command -v cygpath >/dev/null 2>&1; then
  _eff_home="$(cygpath -m "$_eff_home" 2>/dev/null || printf '%s' "$_eff_home")"
  [[ -z "$_pr_arg" ]] || _pr_arg="$(cygpath -m "$_pr_arg" 2>/dev/null || printf '%s' "$_pr_arg")"
  [[ -z "$_uh_arg" ]] || _uh_arg="$(cygpath -m "$_uh_arg" 2>/dev/null || printf '%s' "$_uh_arg")"
fi

_ag_args=("install" "antigravity" "--action" "$ACTION" "--b3-home" "$_eff_home")
[[ -z "$_pr_arg" ]] || _ag_args+=("--plugin-root" "$_pr_arg")
[[ -z "$_uh_arg" ]] || _ag_args+=("--user-home" "$_uh_arg")
if $DRY_RUN; then _ag_args+=("--dry-run"); fi
if $FORCE; then _ag_args+=("--force"); fi
exec "$_b3_bin" "${_ag_args[@]}"
