#!/usr/bin/env bash
# Thin optional GitHub verification wrapper delegating to scripts/lib/b3-github-verify.mjs.
# Usage: ./scripts/b3-github-verify.sh --mode pre-merge|post-merge [--repo-root <dir>] [--repo <owner/name>] --pr-number <N>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MJS_RAW="${SCRIPT_DIR}/lib/b3-github-verify.mjs"
if [[ ! -f "$MJS_RAW" ]]; then
  echo "GH_VERIFY_ERROR: missing_verifier_module"
  exit 1
fi

MODE=""
REPO=""
REPO_ROOT=""
HAS_REPO_ROOT=false
PR_NUMBER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode|-Mode) [[ $# -ge 2 ]] || { echo "GH_VERIFY_ERROR: missing_value($1)"; exit 1; }; MODE="$2"; shift 2 ;;
    --repo|-Repo) [[ $# -ge 2 ]] || { echo "GH_VERIFY_ERROR: missing_value($1)"; exit 1; }; REPO="$2"; shift 2 ;;
    --repo-root|-RepoRoot) [[ $# -ge 2 ]] || { echo "GH_VERIFY_ERROR: missing_value($1)"; exit 1; }; REPO_ROOT="$2"; HAS_REPO_ROOT=true; shift 2 ;;
    --pr-number|-PrNumber) [[ $# -ge 2 ]] || { echo "GH_VERIFY_ERROR: missing_value($1)"; exit 1; }; PR_NUMBER="$2"; shift 2 ;;
    *) echo "GH_VERIFY_ERROR: unknown_option($1)"; exit 1 ;;
  esac
done

case "$MODE" in
  pre-merge|post-merge) ;;
  *) echo "GH_VERIFY_ERROR: invalid_mode"; exit 1 ;;
esac

PR_TRIM="$(printf '%s' "$PR_NUMBER" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
if [[ ! "$PR_TRIM" =~ ^[1-9][0-9]*$ ]]; then
  echo "GH_VERIFY_ERROR: invalid_pr_number"
  exit 1
fi

REPO_TRIM="$(printf '%s' "$REPO" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
if [[ -n "$REPO_TRIM" ]]; then
  if [[ ! "$REPO_TRIM" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ || "$REPO_TRIM" == *".."* ]]; then
    echo "GH_VERIFY_ERROR: invalid_repo"
    exit 1
  fi
fi

# Validate origin remote upfront before requiring `gh`, so invalid/non-GitHub origin fails deterministically (exit 1)
if $HAS_REPO_ROOT || [[ -z "$REPO_TRIM" ]]; then
  ROOT_CHECK="${REPO_ROOT:-.}"
  [[ -n "$ROOT_CHECK" ]] || ROOT_CHECK="."
  ORIGIN_URL=""
  if ! ORIGIN_URL="$(git -C "$ROOT_CHECK" remote get-url origin 2>/dev/null)"; then
    echo "GH_VERIFY_ERROR: origin_remote_missing"
    exit 1
  fi
  ORIGIN_TRIM="$(printf '%s' "$ORIGIN_URL" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s|/*$||;s|\.git$||')"
  _re_https='^[Hh][Tt][Tt][Pp][Ss]://([^/@[:space:]]+@)?[Gg][Ii][Tt][Hh][Uu][Bb]\.[Cc][Oo][Mm]/([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)$'
  _re_ssh='^([Ss][Ss][Hh]://)?[Gg][Ii][Tt]@[Gg][Ii][Tt][Hh][Uu][Bb]\.[Cc][Oo][Mm][:/]([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)$'
  ORIGIN_SLUG=""
  if [[ "$ORIGIN_TRIM" =~ $_re_https ]]; then
    ORIGIN_SLUG="${BASH_REMATCH[2]}"
  elif [[ "$ORIGIN_TRIM" =~ $_re_ssh ]]; then
    ORIGIN_SLUG="${BASH_REMATCH[2]}"
  fi
  if [[ -z "$ORIGIN_SLUG" || "$ORIGIN_SLUG" == *".."* ]]; then
    echo "GH_VERIFY_ERROR: origin_remote_not_github"
    exit 1
  fi
  if [[ -n "$REPO_TRIM" ]]; then
    _r_low="$(printf '%s' "$REPO_TRIM" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    _o_low="$(printf '%s' "$ORIGIN_SLUG" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    if [[ "$_r_low" != "$_o_low" ]]; then
      echo "GH_VERIFY_ERROR: repo_mismatch"
      exit 1
    fi
  fi
  REPO_TRIM="$ORIGIN_SLUG"
fi

if ! command -v node >/dev/null 2>&1; then
  echo "GH_VERIFY_UNAVAILABLE: node_runtime_unavailable"
  exit 2
fi

MJS_WIN="$(cygpath -m "$MJS_RAW" 2>/dev/null || printf '%s' "$MJS_RAW")"
BASH_WIN="$(cygpath -m "${B3_BASH_BIN:-$BASH}" 2>/dev/null || printf '%s' "${B3_BASH_BIN:-$BASH}")"

if [[ -n "$BASH_WIN" ]]; then
  exec node "$MJS_WIN" --mode "$MODE" --repo "$REPO_TRIM" --pr-number "$PR_TRIM" --bash-bin "$BASH_WIN"
fi
exec node "$MJS_WIN" --mode "$MODE" --repo "$REPO_TRIM" --pr-number "$PR_TRIM"
