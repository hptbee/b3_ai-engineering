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

if $FAST; then
  run_step "cargo build --bin b3" cargo build --bin b3
  run_step "b3 context measure --strict" ./target/debug/b3 context measure --strict
  run_step "cargo test --lib --test eval_contracts" cargo test --lib --test eval_contracts
else
  run_step "cargo build --release" cargo build --release
  run_step "b3 context measure --strict" ./target/release/b3 context measure --strict
  run_step "cargo test" cargo test
fi
