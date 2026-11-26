#!/usr/bin/env bash
# Attach a separate product repository to this B3 checkout via native `b3 install product`.
# Usage: ./adapters/install-product.sh --product-root <dir> [--b3-home <dir>] [--host cursor|codex|claude|antigravity|all] [--dry-run] [--force]

set -euo pipefail

PRODUCT_ROOT=""
B3_HOME=""
HOST_NAME="cursor"
DRY_RUN=false
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --product-root) PRODUCT_ROOT="$2"; shift 2 ;;
    --b3-home) B3_HOME="$2"; shift 2 ;;
    --host) HOST_NAME="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --force) FORCE=true; shift ;;
    -h|--help)
      echo "Usage: $0 --product-root <dir> [--b3-home <dir>] [--host cursor|codex|claude|antigravity|all] [--dry-run] [--force]"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

case "$HOST_NAME" in
  cursor|codex|claude|antigravity|all) ;;
  *) echo "error: invalid --host '$HOST_NAME' (expected cursor|codex|claude|antigravity|all)" >&2; exit 1 ;;
esac

[[ -n "$PRODUCT_ROOT" ]] || { echo "error: --product-root is required" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_b3_home_default="$(cd "${SCRIPT_DIR}/.." && pwd)"

_b3_bin=""
if [[ -n "${B3_BIN:-}" ]]; then
  if [[ -f "$B3_BIN" ]]; then
    _b3_bin="$B3_BIN"
  else
    echo "b3 native binary not found; build with 'cargo build --release' or set B3_BIN" >&2
    exit 1
  fi
elif [[ -f "${_b3_home_default}/target/release/b3.exe" ]]; then
  _b3_bin="${_b3_home_default}/target/release/b3.exe"
elif [[ -f "${_b3_home_default}/target/release/b3" ]]; then
  _b3_bin="${_b3_home_default}/target/release/b3"
elif [[ -f "${_b3_home_default}/target/debug/b3.exe" ]]; then
  _b3_bin="${_b3_home_default}/target/debug/b3.exe"
elif [[ -f "${_b3_home_default}/target/debug/b3" ]]; then
  _b3_bin="${_b3_home_default}/target/debug/b3"
elif command -v b3 >/dev/null 2>&1; then
  _b3_bin="$(command -v b3)"
else
  echo "b3 native binary not found; build with 'cargo build --release' or set B3_BIN" >&2
  exit 1
fi

_eff_home="${B3_HOME:-$_b3_home_default}"
_prod_arg="$PRODUCT_ROOT"
_home_arg="$_eff_home"
if command -v cygpath >/dev/null 2>&1; then
  _prod_arg="$(cygpath -m "$PRODUCT_ROOT" 2>/dev/null || printf '%s' "$PRODUCT_ROOT")"
  _home_arg="$(cygpath -m "$_eff_home" 2>/dev/null || printf '%s' "$_eff_home")"
fi

_inst_args=("install" "product" "--product-root" "$_prod_arg" "--b3-home" "$_home_arg" "--host" "$HOST_NAME")
if $DRY_RUN; then _inst_args+=("--dry-run"); fi
if $FORCE; then _inst_args+=("--force"); fi
exec "$_b3_bin" "${_inst_args[@]}"
