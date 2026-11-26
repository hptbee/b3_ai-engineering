#!/usr/bin/env bash
set -euo pipefail

FAST=false
for arg in "$@"; do
  case "$arg" in
    --fast) FAST=true ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

run_step() {
  local name="$1"
  shift
  echo "=== ${name} ==="
  local t0 t1
  t0="$(date +%s)"
  "$@"
  t1="$(date +%s)"
  echo "--- ${name}: $((t1 - t0))s ---"
}

run_step "cargo fmt --check" cargo fmt --check
run_step "cargo clippy --all-targets -- -D warnings" cargo clippy --all-targets -- -D warnings
run_step "measure-context.sh --strict" bash ./scripts/measure-context.sh --strict
run_step "validate-evals.sh" bash ./scripts/validate-evals.sh

if $FAST; then
  run_step "cargo test --lib" cargo test --lib
else
  run_step "cargo build --release" cargo build --release
  export B3_BIN="${REPO_ROOT}/target/release/b3"
  run_step "cargo test" cargo test
  run_step "validate-merge-security.sh" bash ./scripts/validate-merge-security.sh --allow-incomplete-pwsh
fi
