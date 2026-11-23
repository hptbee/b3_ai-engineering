#!/usr/bin/env bash
# Unified global installer dispatcher for B3 AI Engineering (Cursor and Antigravity).
# Dispatches to adapters/cursor/install-global.sh and adapters/antigravity/install-plugin.sh without duplicating host logic.
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
if [[ -z "$B3_HOME" ]]; then
  B3_HOME="$(cd "${SCRIPT_DIR}/.." && pwd)"
else
  [[ -d "$B3_HOME" ]] || { echo "error: B3Home directory not found: $B3_HOME" >&2; exit 1; }
  B3_HOME="$(cd "$B3_HOME" && pwd)"
fi

CURSOR_SCRIPT="${SCRIPT_DIR}/cursor/install-global.sh"
ANTIGRAVITY_SCRIPT="${SCRIPT_DIR}/antigravity/install-plugin.sh"

if [[ "$HOST_NAME" == "cursor" || "$HOST_NAME" == "all" ]]; then
  [[ -f "$CURSOR_SCRIPT" ]] || { echo "error: missing Cursor global installer: $CURSOR_SCRIPT" >&2; exit 1; }
fi
if [[ "$HOST_NAME" == "antigravity" || "$HOST_NAME" == "all" ]]; then
  [[ -f "$ANTIGRAVITY_SCRIPT" ]] || { echo "error: missing Antigravity plugin installer: $ANTIGRAVITY_SCRIPT" >&2; exit 1; }
fi

COMMON_FLAGS=()
COMMON_FLAGS+=("--b3-home" "$B3_HOME")
[[ -n "$USER_HOME" ]] && COMMON_FLAGS+=("--user-home" "$USER_HOME")
$DRY_RUN && COMMON_FLAGS+=("--dry-run")
$FORCE && COMMON_FLAGS+=("--force")

OVERALL_EXIT=0
SUMMARY_LINES=()

run_host() {
  local target_host="$1" script_path="$2"
  shift 2
  echo "=== [${target_host}] action=${ACTION} ==="
  set +e
  "$BASH" "$script_path" "$ACTION" "${COMMON_FLAGS[@]}" "$@"
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    OVERALL_EXIT=1
    SUMMARY_LINES+=("host=${target_host} status=FAIL exit=${rc}")
  else
    SUMMARY_LINES+=("host=${target_host} status=OK exit=0")
  fi
}

if [[ "$HOST_NAME" == "cursor" || "$HOST_NAME" == "all" ]]; then
  CURSOR_EXTRA=()
  [[ -n "$CURSOR_HOME" ]] && CURSOR_EXTRA+=("--cursor-home" "$CURSOR_HOME")
  if [[ ${#CURSOR_EXTRA[@]} -gt 0 ]]; then
    run_host "cursor" "$CURSOR_SCRIPT" "${CURSOR_EXTRA[@]}"
  else
    run_host "cursor" "$CURSOR_SCRIPT"
  fi
fi

if [[ "$HOST_NAME" == "antigravity" || "$HOST_NAME" == "all" ]]; then
  AG_EXTRA=()
  [[ -n "$PLUGIN_ROOT" ]] && AG_EXTRA+=("--plugin-root" "$PLUGIN_ROOT")
  if [[ ${#AG_EXTRA[@]} -gt 0 ]]; then
    run_host "antigravity" "$ANTIGRAVITY_SCRIPT" "${AG_EXTRA[@]}"
  else
    run_host "antigravity" "$ANTIGRAVITY_SCRIPT"
  fi
fi

for line in "${SUMMARY_LINES[@]}"; do
  echo "$line"
done

if [[ $OVERALL_EXIT -ne 0 ]]; then
  echo "GLOBAL_FAIL: host=${HOST_NAME} action=${ACTION}"
  exit 1
fi
echo "GLOBAL_OK: host=${HOST_NAME} action=${ACTION}"
exit 0
