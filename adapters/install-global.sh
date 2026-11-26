#!/usr/bin/env bash
# Unified global installer dispatcher for B3 AI Engineering (Cursor and Antigravity).
# Usage: ./adapters/install-global.sh [install|update|verify|uninstall] [--host cursor|antigravity|all] [--b3-home PATH] [--cursor-home PATH] [--plugin-root PATH] [--user-home PATH] [--dry-run] [--force]
set -euo pipefail

ACTION="install"
ACTION_SET=false
HOST_NAME="all"
B3_HOME=""
CURSOR_HOME=""
PLUGIN_ROOT=""
USER_HOME=""
DRY_RUN=false
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    install|update|verify|uninstall)
      if $ACTION_SET; then
        echo "error: duplicate action '$1'" >&2; exit 1
      fi
      ACTION="$1"; ACTION_SET=true; shift ;;
    --action)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "error: option $1 requires a value" >&2; exit 1; }
      if $ACTION_SET; then
        echo "error: duplicate action '$2'" >&2; exit 1
      fi
      case "$2" in
        install|update|verify|uninstall) ACTION="$2"; ACTION_SET=true ;;
        *) echo "error: invalid action '$2'" >&2; exit 1 ;;
      esac
      shift 2 ;;
    --host)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "error: option $1 requires a value" >&2; exit 1; }
      case "$2" in
        cursor|antigravity|all) HOST_NAME="$2" ;;
        *) echo "error: invalid --host '$2' (expected cursor, antigravity, or all)" >&2; exit 1 ;;
      esac
      shift 2 ;;
    --b3-home)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "error: option $1 requires a value" >&2; exit 1; }
      B3_HOME="$2"; shift 2 ;;
    --cursor-home)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "error: option $1 requires a value" >&2; exit 1; }
      CURSOR_HOME="$2"; shift 2 ;;
    --plugin-root)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "error: option $1 requires a value" >&2; exit 1; }
      PLUGIN_ROOT="$2"; shift 2 ;;
    --user-home)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "error: option $1 requires a value" >&2; exit 1; }
      USER_HOME="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --force) FORCE=true; shift ;;
    -h|--help)
      echo "Usage: $0 [install|update|verify|uninstall] [--host cursor|antigravity|all] [--b3-home PATH] [--cursor-home PATH] [--plugin-root PATH] [--user-home PATH] [--dry-run] [--force]"
      exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_b3_repo_default="$(cd "${SCRIPT_DIR}/.." && pwd)"

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
_ch_arg="$CURSOR_HOME"
_pr_arg="$PLUGIN_ROOT"
_uh_arg="$USER_HOME"
if command -v cygpath >/dev/null 2>&1; then
  _eff_home="$(cygpath -m "$_eff_home" 2>/dev/null || printf '%s' "$_eff_home")"
  [[ -z "$_ch_arg" ]] || _ch_arg="$(cygpath -m "$_ch_arg" 2>/dev/null || printf '%s' "$_ch_arg")"
  [[ -z "$_pr_arg" ]] || _pr_arg="$(cygpath -m "$_pr_arg" 2>/dev/null || printf '%s' "$_pr_arg")"
  [[ -z "$_uh_arg" ]] || _uh_arg="$(cygpath -m "$_uh_arg" 2>/dev/null || printf '%s' "$_uh_arg")"
fi

_gl_args=("install" "global" "--action" "$ACTION" "--host" "$HOST_NAME" "--b3-home" "$_eff_home")
[[ -z "$_ch_arg" ]] || _gl_args+=("--cursor-home" "$_ch_arg")
[[ -z "$_pr_arg" ]] || _gl_args+=("--plugin-root" "$_pr_arg")
[[ -z "$_uh_arg" ]] || _gl_args+=("--user-home" "$_uh_arg")
if $DRY_RUN; then _gl_args+=("--dry-run"); fi
if $FORCE; then _gl_args+=("--force"); fi
exec "$_b3_bin" "${_gl_args[@]}"
